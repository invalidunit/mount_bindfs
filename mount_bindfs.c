#include <sys/mount.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <pthread.h>
#include <dirent.h>
#include <CoreFoundation/CoreFoundation.h>
#include <roothide.h>
#include "libjailbreak_min.h"

// ============================================================================
// 全局配置
// ============================================================================

static const char *PREFS_PATH = "/var/mobile/Library/Preferences/com.nan.auto-bindfs.plist";
static const char *DEFAULT_MOUNT_BASE = ".jbroot/bindfs";

// ============================================================================
// 工具函数
// ============================================================================

static int run_cmd(const char *bin, const char *arg1, const char *arg2) {
    pid_t pid = fork();
    if (pid == 0) {
        execl(bin, bin, arg1, arg2, NULL);
        _exit(127);
    }
    int status;
    waitpid(pid, &status, 0);
    return WIFEXITED(status) ? WEXITSTATUS(status) : -1;
}

static void strip_trailing_slash(char *path) {
    if (!path || !*path) return;
    size_t len = strlen(path);
    while (len > 1 && path[len - 1] == '/') {
        path[--len] = '\0';
    }
}

static void strip_rootfs_prefix(char *path) {
    if (!path) return;
    if (strncmp(path, "/rootfs/", 8) == 0) {
        memmove(path, path + 7, strlen(path + 7) + 1);
    } else if (strcmp(path, "/rootfs") == 0) {
        strcpy(path, "/");
    }
}

// ============================================================================
// CoreFoundation plist 操作
// ============================================================================

static CFDictionaryRef load_prefs(void) {
    const char *path = jbroot(PREFS_PATH);
    CFURLRef url = CFURLCreateFromFileSystemRepresentation(NULL, (const UInt8 *)path, strlen(path), false);
    if (!url) return NULL;
    
    CFReadStreamRef stream = CFReadStreamCreateWithFile(NULL, url);
    CFRelease(url);
    if (!stream) return NULL;
    
    if (!CFReadStreamOpen(stream)) {
        CFRelease(stream);
        return NULL;
    }
    
    CFPropertyListRef plist = CFPropertyListCreateWithStream(NULL, stream, 0, kCFPropertyListMutableContainers, NULL, NULL);
    CFReadStreamClose(stream);
    CFRelease(stream);
    
    if (plist && CFGetTypeID(plist) == CFDictionaryGetTypeID()) {
        return (CFDictionaryRef)plist;
    }
    if (plist) CFRelease(plist);
    return NULL;
}

static int save_prefs(CFDictionaryRef dict) {
    const char *path = jbroot(PREFS_PATH);
    
    // 创建目录
    char dir[PATH_MAX];
    strlcpy(dir, path, sizeof(dir));
    char *slash = strrchr(dir, '/');
    if (slash) {
        *slash = '\0';
        // 递归创建目录
        char tmp[PATH_MAX];
        strlcpy(tmp, dir, sizeof(tmp));
        for (char *p = tmp + 1; *p; p++) {
            if (*p == '/') {
                *p = '\0';
                mkdir(tmp, 0755);
                *p = '/';
            }
        }
        mkdir(tmp, 0755);
    }
    
    CFDataRef data = CFPropertyListCreateData(NULL, dict, kCFPropertyListXMLFormat_v1_0, 0, NULL);
    if (!data) return 0;
    
    FILE *f = fopen(path, "wb");
    if (!f) {
        CFRelease(data);
        return 0;
    }
    fwrite(CFDataGetBytePtr(data), 1, CFDataGetLength(data), f);
    fclose(f);
    CFRelease(data);
    
    chown(path, 501, 501);
    chmod(path, 0644);
    return 1;
}

// ============================================================================
// 文件操作
// ============================================================================

static int is_dir(const char *path) {
    struct stat st;
    return stat(path, &st) == 0 && S_ISDIR(st.st_mode);
}

static int is_empty_dir(const char *path) {
    DIR *d = opendir(path);
    if (!d) return 1;
    struct dirent *e;
    int count = 0;
    while ((e = readdir(d)) && count < 3) {
        if (strcmp(e->d_name, ".") && strcmp(e->d_name, "..")) count++;
    }
    closedir(d);
    return count == 0;
}

static int mkdir_p(const char *path) {
    char tmp[PATH_MAX];
    strlcpy(tmp, path, sizeof(tmp));
    for (char *p = tmp + 1; *p; p++) {
        if (*p == '/') {
            *p = '\0';
            mkdir(tmp, 0755);
            *p = '/';
        }
    }
    return mkdir(tmp, 0755);
}

static int copy_recursive(const char *src, const char *dst) {
    struct stat st;
    if (stat(src, &st) != 0) return -1;
    
    if (S_ISDIR(st.st_mode)) {
        mkdir(dst, st.st_mode);
        DIR *d = opendir(src);
        if (!d) return -1;
        struct dirent *e;
        while ((e = readdir(d))) {
            if (!strcmp(e->d_name, ".") || !strcmp(e->d_name, "..")) continue;
            char src_path[PATH_MAX], dst_path[PATH_MAX];
            snprintf(src_path, sizeof(src_path), "%s/%s", src, e->d_name);
            snprintf(dst_path, sizeof(dst_path), "%s/%s", dst, e->d_name);
            if (copy_recursive(src_path, dst_path) != 0) {
                closedir(d);
                return -1;
            }
        }
        closedir(d);
    } else {
        FILE *in = fopen(src, "rb");
        if (!in) return -1;
        FILE *out = fopen(dst, "wb");
        if (!out) { fclose(in); return -1; }
        char buf[8192];
        size_t n;
        while ((n = fread(buf, 1, sizeof(buf), in)) > 0) {
            fwrite(buf, 1, n, out);
        }
        fclose(in);
        fclose(out);
        chmod(dst, st.st_mode);
    }
    return 0;
}

static int rm_rf(const char *path) {
    struct stat st;
    if (stat(path, &st) != 0) return 0;
    if (S_ISDIR(st.st_mode)) {
        DIR *d = opendir(path);
        if (d) {
            struct dirent *e;
            while ((e = readdir(d))) {
                if (!strcmp(e->d_name, ".") || !strcmp(e->d_name, "..")) continue;
                char sub[PATH_MAX];
                snprintf(sub, sizeof(sub), "%s/%s", path, e->d_name);
                rm_rf(sub);
            }
            closedir(d);
        }
        return rmdir(path);
    }
    return unlink(path);
}

static int copy_dir(const char *src, const char *dst) {
    // 删除已存在的目标
    if (access(dst, F_OK) == 0) {
        rm_rf(dst);
    }
    // 创建父目录
    char parent[PATH_MAX];
    strlcpy(parent, dst, sizeof(parent));
    char *slash = strrchr(parent, '/');
    if (slash && slash != parent) {
        *slash = '\0';
        mkdir_p(parent);
    }
    return copy_recursive(src, dst);
}

// ============================================================================
// 挂载检查和操作
// ============================================================================

static int is_bindfs_mounted(const char *path) {
    if (!path || !*path) return 0;
    char clean[PATH_MAX];
    strlcpy(clean, path, sizeof(clean));
    strip_trailing_slash(clean);
    
    struct statfs *mntbuf;
    int count = getmntinfo(&mntbuf, MNT_NOWAIT);
    if (count <= 0) return 0;
    
    for (int i = 0; i < count; i++) {
        char mnt_clean[PATH_MAX];
        strlcpy(mnt_clean, mntbuf[i].f_mntonname, sizeof(mnt_clean));
        strip_trailing_slash(mnt_clean);
        if (strcmp(mnt_clean, clean) == 0 && strcmp(mntbuf[i].f_fstypename, "bindfs") == 0) {
            return 1;
        }
    }
    return 0;
}

typedef struct { const char *source; const char *dest; } mount_args_t;

static int with_ucred(int (*action)(void *), void *ctx) {
    if (jbclient_root_steal_ucred == NULL) {
        fprintf(stderr, "jbclient_root_steal_ucred not available\n");
        return 1;
    }
    uint64_t orgUcred = 0;
    if (jbclient_root_steal_ucred(0, &orgUcred) != 0) {
        fprintf(stderr, "Failed to steal kernel ucred\n");
        return 1;
    }
    int ret = action(ctx);
    jbclient_root_steal_ucred(orgUcred, NULL);
    return ret;
}

static int do_mount_action(void *ctx) {
    mount_args_t *a = ctx;
    int ret = mount("bindfs", a->dest, MNT_RDONLY, (void *)a->source);
    if (ret != 0) perror("mount failed");
    return ret;
}

static int do_unmount_action(void *ctx) {
    const char *path = ctx;
    int ret = unmount(path, MNT_FORCE);
    if (ret != 0) perror("unmount failed");
    return ret;
}

static int do_mount(const char *source, const char *dest) {
    mount_args_t args = { source, dest };
    return with_ucred(do_mount_action, &args);
}

static int do_unmount(const char *path) {
    return with_ucred(do_unmount_action, (void *)path);
}

// ============================================================================
// 处理单个路径
// ============================================================================

static int handle_one_path(const char *path_in, const char *mount_base, int copy_mode, int is_unmount) {
    char path_buf[PATH_MAX];
    strlcpy(path_buf, path_in, sizeof(path_buf));
    strip_trailing_slash(path_buf);
    strip_rootfs_prefix(path_buf);
    
    char real_path[PATH_MAX];
    if (!realpath(path_buf, real_path)) {
        printf("status: Failure\nLog: source path not found: %s\n", path_buf);
        return 1;
    }
    strip_trailing_slash(real_path);
    
    char dst[PATH_MAX];
    snprintf(dst, sizeof(dst), "%s%s", mount_base, real_path);
    strip_trailing_slash(dst);
    
    if (is_unmount) {
        printf("Will unmount \"%s\"\n", real_path);
        if (!is_bindfs_mounted(real_path)) {
            printf("status: Failure\nLog: not mounted: %s\n", real_path);
            return 1;
        }
        if (do_unmount(real_path) != 0) {
            printf("status: Failure\nLog: unmount failed\n");
            return 1;
        }
        printf("status: Success\n");
        return 0;
    }
    
    printf("Will mount \"%s\" -> \"%s\"\n", dst, real_path);
    
    if (is_bindfs_mounted(real_path)) {
        if (copy_mode != 1) {
            printf("status: Skipped\nLog: already mounted: %s\n", real_path);
            return 2;
        }
        do_unmount(real_path);
    }
    
    int need_copy = (copy_mode == 1);
    if (copy_mode == 0) {
        if (!is_dir(dst) || is_empty_dir(dst)) need_copy = 1;
    }
    
    if (need_copy) {
        if (copy_dir(real_path, dst) != 0) {
            printf("status: Failure\nLog: copy failed\n");
            return 1;
        }
    } else if (copy_mode == 2) {
        mkdir_p(dst);
    }
    
    if (do_mount(dst, real_path) != 0) {
        printf("status: Failure\nLog: mount failed\n");
        return 1;
    }
    printf("status: Success\n");
    return 0;
}

// ============================================================================
// 多线程处理
// ============================================================================

typedef struct {
    const char *path;
    const char *mount_base;
    int copy_mode;
    int is_unmount;
    int result;
} thread_args_t;

static void *thread_worker(void *arg) {
    thread_args_t *a = arg;
    a->result = handle_one_path(a->path, a->mount_base, a->copy_mode, a->is_unmount);
    return NULL;
}

// ============================================================================
// 帮助信息
// ============================================================================

static void print_usage(void) {
    printf("Usage: mount_bindfs [OPTIONS...] [PATH...]\n"
           "\t-h\t\tPrint this help\n"
           "\t-l\t\tList folders that will be mounted on next jailbreak\n"
           "\t-s\t\tSet folders to automatically mount (overwrites previous)\n"
           "\t-s --add PATH\tAdd PATH to automatic mount list\n"
           "\t-s --del PATH\tRemove PATH from automatic mount list\n"
           "\t-u\t\tUnmount folders that have been mounted as bindfs\n"
           "\t--copy\t\tForce copy of all files\n"
           "\t--skip-copy\tSkip copy check\n"
           "\n"
           "Examples:\n"
           "\tmount_bindfs \"/System/Library/Fonts\"\n"
           "\tmount_bindfs \"/System/Library/Fonts\" \"/bin\"\n"
           "\tmount_bindfs --copy \"/System/Library/Fonts\"\n"
           "\tmount_bindfs -s \"/System/Library/Fonts\"\n"
           "\tmount_bindfs -s --add \"/bin\"\n"
           "\tmount_bindfs -s --del \"/bin\"\n"
           "\tmount_bindfs -u \"/System/Library/Fonts\"\n");
}

// ============================================================================
// 主函数
// ============================================================================

#define MAX_PATHS 256

int main(int argc, char *argv[]) {
    setvbuf(stdout, NULL, _IOLBF, 0);
    if (getuid() != 0 && geteuid() == 0) setuid(0);
    
    int copy_mode = 0;
    int is_auto = 0, is_unmount = 0, is_set = 0, is_list = 0, is_mount = 0;
    int is_prefs_mount = 0;
    int set_mode = 0;
    char *map_src = NULL, *map_dst = NULL;
    char *paths[MAX_PATHS];
    int path_count = 0;
    
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "-h") || !strcmp(argv[i], "--help")) {
            print_usage();
            return 0;
        } else if (!strcmp(argv[i], "--copy")) {
            copy_mode = 1;
        } else if (!strcmp(argv[i], "--skip-copy")) {
            copy_mode = 2;
        } else if (!strcmp(argv[i], "--auto")) {
            is_auto = 1;
        } else if (!strcmp(argv[i], "--prefs")) {
            if (i + 1 < argc && !strcmp(argv[i+1], "mount")) {
                is_prefs_mount = 1;
                i++;
            }
        } else if (!strcmp(argv[i], "-u")) {
            is_unmount = 1;
        } else if (!strcmp(argv[i], "-s")) {
            is_set = 1;
        } else if (!strcmp(argv[i], "--add")) {
            set_mode = 1;
        } else if (!strcmp(argv[i], "--del")) {
            set_mode = 2;
        } else if (!strcmp(argv[i], "-l")) {
            is_list = 1;
        } else if (!strcmp(argv[i], "-m")) {
            is_mount = 1;
            if (i + 2 < argc) {
                map_src = strdup(argv[++i]);
                map_dst = strdup(argv[++i]);
                strip_trailing_slash(map_src);
                strip_trailing_slash(map_dst);
                strip_rootfs_prefix(map_src);
                strip_rootfs_prefix(map_dst);
            }
            break;
        } else if (argv[i][0] == '/') {
            if (path_count < MAX_PATHS) {
                char *p = strdup(argv[i]);
                strip_trailing_slash(p);
                strip_rootfs_prefix(p);
                paths[path_count++] = p;
            }
        } else {
            fprintf(stderr, "Error: invalid argument %s\n", argv[i]);
            return 2;
        }
    }
    
    CFMutableDictionaryRef prefs = (CFMutableDictionaryRef)load_prefs();
    if (!prefs) {
        prefs = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    }
    
    // ---------- -l 列出路径 ----------
    if (is_list) {
        CFArrayRef arr = CFDictionaryGetValue(prefs, CFSTR("path"));
        if (!arr || CFArrayGetCount(arr) == 0) {
            printf("You have not set any folder for automatic mount.\n");
        } else {
            for (CFIndex i = 0; i < CFArrayGetCount(arr); i++) {
                CFStringRef s = CFArrayGetValueAtIndex(arr, i);
                char buf[PATH_MAX];
                CFStringGetCString(s, buf, sizeof(buf), kCFStringEncodingUTF8);
                printf("%s\n", buf);
            }
        }
        CFRelease(prefs);
        return 0;
    }
    
    // ---------- -s 设置路径 ----------
    if (is_set) {
        CFDictionarySetValue(prefs, CFSTR("Enable"), kCFBooleanTrue);
        if (!CFDictionaryContainsKey(prefs, CFSTR("root"))) {
            CFDictionarySetValue(prefs, CFSTR("root"), CFStringCreateWithCString(NULL, DEFAULT_MOUNT_BASE, kCFStringEncodingUTF8));
        }
        
        CFMutableArrayRef arr = (CFMutableArrayRef)CFDictionaryGetValue(prefs, CFSTR("path"));
        if (!arr) {
            arr = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
        } else {
            arr = CFArrayCreateMutableCopy(NULL, 0, arr);
        }
        
        if (set_mode == 1) {
            for (int i = 0; i < path_count; i++) {
                CFStringRef s = CFStringCreateWithCString(NULL, paths[i], kCFStringEncodingUTF8);
                if (!CFArrayContainsValue(arr, CFRangeMake(0, CFArrayGetCount(arr)), s)) {
                    CFArrayAppendValue(arr, s);
                }
                CFRelease(s);
            }
        } else if (set_mode == 2) {
            for (int i = 0; i < path_count; i++) {
                CFStringRef s = CFStringCreateWithCString(NULL, paths[i], kCFStringEncodingUTF8);
                CFIndex idx = CFArrayGetFirstIndexOfValue(arr, CFRangeMake(0, CFArrayGetCount(arr)), s);
                if (idx != -1) CFArrayRemoveValueAtIndex(arr, idx);
                CFRelease(s);
            }
        } else {
            CFArrayRemoveAllValues(arr);
            for (int i = 0; i < path_count; i++) {
                CFStringRef s = CFStringCreateWithCString(NULL, paths[i], kCFStringEncodingUTF8);
                CFArrayAppendValue(arr, s);
                CFRelease(s);
            }
        }
        
        CFDictionarySetValue(prefs, CFSTR("path"), arr);
        int ok = save_prefs(prefs);
        printf("%s\n", ok ? "status: Success" : "status: Failure");
        if (ok) {
            printf("Automatic mount list:\n");
            for (CFIndex i = 0; i < CFArrayGetCount(arr); i++) {
                CFStringRef s = CFArrayGetValueAtIndex(arr, i);
                char buf[PATH_MAX];
                CFStringGetCString(s, buf, sizeof(buf), kCFStringEncodingUTF8);
                printf("%s\n", buf);
            }
        }
        CFRelease(arr);
        CFRelease(prefs);
        return ok ? 0 : 1;
    }
    
    // ---------- --auto ----------
    if (is_auto) {
        if (access(jbroot("/basebin/.safe_mode"), F_OK) == 0) { CFRelease(prefs); return 0; }
        if (access(rootfs("/var/mobile/.not_auto_mount"), F_OK) == 0) { CFRelease(prefs); return 0; }
        
        CFBooleanRef enable = CFDictionaryGetValue(prefs, CFSTR("Enable"));
        if (enable && !CFBooleanGetValue(enable)) { CFRelease(prefs); return 0; }
        
        CFArrayRef arr = CFDictionaryGetValue(prefs, CFSTR("path"));
        if (!arr || CFArrayGetCount(arr) == 0) { CFRelease(prefs); return 0; }
        
        for (CFIndex i = 0; i < CFArrayGetCount(arr) && path_count < MAX_PATHS; i++) {
            CFStringRef s = CFArrayGetValueAtIndex(arr, i);
            char buf[PATH_MAX];
            CFStringGetCString(s, buf, sizeof(buf), kCFStringEncodingUTF8);
            paths[path_count++] = strdup(buf);
        }
        is_mount = 1;
    }
    
    // ---------- --prefs mount ----------
    if (is_prefs_mount) {
        CFArrayRef arr = CFDictionaryGetValue(prefs, CFSTR("path"));
        if (!arr || CFArrayGetCount(arr) == 0) {
            printf("No paths configured.\n");
            CFRelease(prefs);
            return 0;
        }
        for (CFIndex i = 0; i < CFArrayGetCount(arr) && path_count < MAX_PATHS; i++) {
            CFStringRef s = CFArrayGetValueAtIndex(arr, i);
            char buf[PATH_MAX];
            CFStringGetCString(s, buf, sizeof(buf), kCFStringEncodingUTF8);
            paths[path_count++] = strdup(buf);
        }
        is_mount = 1;
    }
    
    if (!is_mount && !is_unmount) {
        if (path_count) {
            is_mount = 1;
        } else {
            print_usage();
            CFRelease(prefs);
            return 1;
        }
    }
    
    if (!path_count && !map_src) {
        print_usage();
        CFRelease(prefs);
        return 1;
    }
    
    // ---------- 计算挂载基路径 ----------
    char mount_base[PATH_MAX];
    CFStringRef root_cf = CFDictionaryGetValue(prefs, CFSTR("root"));
    char root_buf[PATH_MAX];
    strlcpy(root_buf, DEFAULT_MOUNT_BASE, sizeof(root_buf));
    if (root_cf) CFStringGetCString(root_cf, root_buf, sizeof(root_buf), kCFStringEncodingUTF8);
    
    if (strcmp(root_buf, ".jbroot") == 0) {
        strlcpy(mount_base, jbroot("/"), sizeof(mount_base));
    } else if (strncmp(root_buf, ".jbroot/", 8) == 0) {
        strlcpy(mount_base, jbroot(root_buf + 7), sizeof(mount_base));
    } else if (root_buf[0] == '/') {
        strlcpy(mount_base, root_buf, sizeof(mount_base));
    } else {
        strlcpy(mount_base, jbroot(root_buf), sizeof(mount_base));
    }
    strip_trailing_slash(mount_base);
    
    unlink(jbroot("/.bindfs"));
    symlink(mount_base, jbroot("/.bindfs"));
    
    // ---------- -m 指定一对一映射 ----------
    if (is_mount && map_src && map_dst) {
        printf("Will mount \"%s\" -> \"%s\"\n", map_src, map_dst);
        if (copy_mode != 2) {
            if (copy_dir(map_src, map_dst) != 0) {
                printf("status: Failure\nLog: copy failed\n");
                CFRelease(prefs);
                return 1;
            }
        } else {
            mkdir_p(map_dst);
        }
        if (do_mount(map_src, map_dst) != 0) {
            printf("status: Failure\nLog: mount failed\n");
            CFRelease(prefs);
            return 1;
        }
        printf("status: Success\n");
        CFRelease(prefs);
        free(map_src);
        free(map_dst);
        return 0;
    }
    
    // ---------- 多线程并发处理 ----------
    pthread_t threads[MAX_PATHS];
    thread_args_t args[MAX_PATHS];
    
    for (int i = 0; i < path_count; i++) {
        args[i].path = paths[i];
        args[i].mount_base = mount_base;
        args[i].copy_mode = copy_mode;
        args[i].is_unmount = is_unmount;
        args[i].result = 0;
        pthread_create(&threads[i], NULL, thread_worker, &args[i]);
    }
    
    int exit_status = 0;
    int mounted_count = 0;
    for (int i = 0; i < path_count; i++) {
        pthread_join(threads[i], NULL);
        if (args[i].result == 0) mounted_count++;
        else if (args[i].result != 2) exit_status = 1;
        free(paths[i]);
    }
    
    // 自动模式：至少有一个真正新挂载才生效
    if (is_auto && exit_status == 0 && mounted_count > 0) {
        // 读取延时（number 格式）
        CFNumberRef sleep_cf = CFDictionaryGetValue(prefs, CFSTR("sleep"));
        float sleep_sec = 0;
        if (sleep_cf && CFGetTypeID(sleep_cf) == CFNumberGetTypeID()) {
            CFNumberGetValue(sleep_cf, kCFNumberFloatType, &sleep_sec);
        }
        if (sleep_sec > 0) {
            printf("[=] Sleep %.1f seconds...\n", sleep_sec);
            usleep((useconds_t)(sleep_sec * 1000000));
        }
        
        CFNumberRef reboot_cf = CFDictionaryGetValue(prefs, CFSTR("reboot"));
        int mode = 1;
        if (reboot_cf && CFGetTypeID(reboot_cf) == CFNumberGetTypeID()) {
            CFNumberGetValue(reboot_cf, kCFNumberIntType, &mode);
        }
        
        if (mode == 2) {
            printf("[=] Restart desktop...\n");
            run_cmd(jbroot("/usr/bin/killall"), "-9", "cfprefsd");
            run_cmd(jbroot("/usr/bin/killall"), "-9", "backboardd");
        } else {
            printf("[=] Reboot userspace...\n");
            execl(jbroot("/usr/bin/launchctl"), "launchctl", "reboot", "userspace", (char *)NULL);
            perror("execl launchctl failed");
        }
    }
    
    CFRelease(prefs);
    return exit_status;
}
