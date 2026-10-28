#import <sys/mount.h>
#import <sys/stat.h>
#import <sys/wait.h>
#import <unistd.h>
#import <stdlib.h>
#import <stdio.h>
#import <string.h>
#import <Foundation/Foundation.h>
#import <spawn.h>
#include <roothide.h>
#import "libjailbreak_min.h"

// 直接 execl 执行命令（不走 shell）
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

// ============================================================================
// 全局配置
// ============================================================================

// 偏好设置文件路径（jbroot 相对路径）
static const char *PREFS_PATH = "/var/mobile/Library/Preferences/com.nan.auto-bindfs.plist";

// 默认挂载基路径
static const char *DEFAULT_MOUNT_BASE = ".jbroot/bindfs";

// ============================================================================
// 工具函数
// ============================================================================

// 去掉路径结尾的斜杠（保留根目录 "/"）
static void strip_trailing_slash(char *path) {
    if (!path || !*path) return;
    size_t len = strlen(path);
    while (len > 1 && path[len - 1] == '/') {
        path[--len] = '\0';
    }
}

// 剥离 /rootfs 前缀（方便终端自动补全）
static void strip_rootfs_prefix(char *path) {
    if (!path) return;
    if (strncmp(path, "/rootfs/", 8) == 0) {
        memmove(path, path + 7, strlen(path + 7) + 1);  // 保留开头的 /
    } else if (strcmp(path, "/rootfs") == 0) {
        strcpy(path, "/");
    }
}

// 打印帮助信息
void print_usage(void) {
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

// 读取偏好设置
static NSDictionary *load_prefs(void) {
    NSString *path = [NSString stringWithUTF8String:jbroot(PREFS_PATH)];
    if (![[NSFileManager defaultManager] fileExistsAtPath:path]) return nil;
    return [NSDictionary dictionaryWithContentsOfFile:path];
}

// 保存偏好设置
static BOOL save_prefs(NSDictionary *dict) {
    NSString *path = [NSString stringWithUTF8String:jbroot(PREFS_PATH)];
    NSString *dir = [path stringByDeletingLastPathComponent];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:nil];
    BOOL ok = [dict writeToFile:path atomically:YES];
    if (ok) {
        chown(path.UTF8String, 501, 501);
        chmod(path.UTF8String, 0644);
    }
    return ok;
}

// 用 getmntinfo 检查某个路径是否已经被 bindfs 挂载（已处理结尾斜杠）
static BOOL is_bindfs_mounted(const char *path) {
    if (!path || !*path) return NO;

    char clean[PATH_MAX];
    strlcpy(clean, path, sizeof(clean));
    strip_trailing_slash(clean);

    struct statfs *mntbuf;
    int count = getmntinfo(&mntbuf, MNT_NOWAIT);
    if (count <= 0) return NO;

    for (int i = 0; i < count; i++) {
        char mnt_clean[PATH_MAX];
        strlcpy(mnt_clean, mntbuf[i].f_mntonname, sizeof(mnt_clean));
        strip_trailing_slash(mnt_clean);

        if (strcmp(mnt_clean, clean) == 0 &&
            strcmp(mntbuf[i].f_fstypename, "bindfs") == 0) {
            return YES;
        }
    }
    return NO;
}

// 在窃取内核凭证的上下文中执行操作
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

// 挂载参数
typedef struct { const char *source; const char *dest; } mount_args_t;

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

// 执行 bindfs 挂载（始终只读）
static int do_mount(const char *source, const char *dest) {
    mount_args_t args = { source, dest };
    return with_ucred(do_mount_action, &args);
}

// 执行卸载
static int do_unmount(const char *path) {
    return with_ucred(do_unmount_action, (void *)path);
}

// 用 NSFileManager 复制目录
static BOOL copy_dir(NSString *src, NSString *dst, NSError **error) {
    NSFileManager *fm = [NSFileManager defaultManager];
    if ([fm fileExistsAtPath:dst]) {
        if (![fm removeItemAtPath:dst error:error]) return NO;
    }
    // 先创建父目录
    NSString *parent = [dst stringByDeletingLastPathComponent];
    [fm createDirectoryAtPath:parent withIntermediateDirectories:YES attributes:nil error:nil];
    return [fm copyItemAtPath:src toPath:dst error:error];
}

// ============================================================================
// 子进程处理单个路径
// ============================================================================
static int handle_one_path(NSString *pathStr,
                           const char *mount_base,
                           int copy_mode,
                           int is_unmount) {
    // 用户传入真实路径，剥离 /rootfs 前缀
    char path_buf[PATH_MAX];
    strlcpy(path_buf, pathStr.UTF8String, sizeof(path_buf));
    strip_trailing_slash(path_buf);
    strip_rootfs_prefix(path_buf);
    const char *path = path_buf;

    // 直接 realpath 真实系统路径
    char real_path[PATH_MAX];
    if (!realpath(path, real_path)) {
        printf("status: Failure\nLog: source path not found: %s\n", path);
        return 1;
    }
    strip_trailing_slash(real_path);

    // 挂载点用规范化后的真实路径
    const char *clean_path = real_path;

    // 目标路径 = mount_base + 相对路径
    char dst[PATH_MAX];
    snprintf(dst, sizeof(dst), "%s%s", mount_base, clean_path);
    strip_trailing_slash(dst);
    NSString *dstPath = @(dst);
    NSString *srcPath = @(real_path);
    NSFileManager *fm = [NSFileManager defaultManager];

    // ---------- 卸载模式 ----------
    if (is_unmount) {
        printf("Will unmount \"%s\"\n", clean_path);
        if (!is_bindfs_mounted(clean_path)) {
            printf("status: Failure\nLog: not mounted: %s\n", clean_path);
            return 1;
        }
        if (do_unmount(clean_path) != 0) {
            printf("status: Failure\nLog: unmount failed\n");
            return 1;
        }
        printf("status: Success\n");
        return 0;
    }

    // ---------- 挂载模式 ----------
    printf("Will mount \"%s\" -> \"%s\"\n", dst, clean_path);

    if (is_bindfs_mounted(clean_path)) {
        if (copy_mode != 1) {
            // 已挂载返回 2（跳过），不是真正的成功
            printf("status: Skipped\nLog: already mounted: %s\n", clean_path);
            return 2;
        }
        do_unmount(clean_path);
    }

    BOOL need_copy = (copy_mode == 1);
    if (copy_mode == 0) {
        BOOL isDir = NO;
        if (![fm fileExistsAtPath:dstPath isDirectory:&isDir] || !isDir) {
            need_copy = YES;
        } else {
            NSArray *contents = [fm contentsOfDirectoryAtPath:dstPath error:nil];
            if (!contents.count) need_copy = YES;
        }
    }

    if (need_copy) {
        NSError *err = nil;
        if (!copy_dir(srcPath, dstPath, &err)) {
            printf("status: Failure\nLog: copy failed: %s\n",
                   err.localizedDescription.UTF8String ?: "unknown");
            return 1;
        }
    } else if (copy_mode == 2) {
        [fm createDirectoryAtPath:dstPath withIntermediateDirectories:YES attributes:nil error:nil];
    }

    if (do_mount(dst, clean_path) != 0) {
        printf("status: Failure\nLog: mount failed\n");
        return 1;
    }

    printf("status: Success\n");
    return 0;
}

// ============================================================================
// 主函数
// ============================================================================
int main(int argc, char *argv[]) {
    setvbuf(stdout, NULL, _IOLBF, 0);
    if (getuid() != 0 && geteuid() == 0) setuid(0);

    // ---------- 解析命令行参数 ----------
    int copy_mode = 0;
    int is_auto = 0, is_unmount = 0, is_set = 0, is_list = 0, is_mount = 0;
    int is_prefs_mount = 0;  // --prefs mount
    int set_mode = 0;  // 0=overwrite, 1=add, 2=del
    NSString *map_src = nil, *map_dst = nil;  // -m src dst
    NSMutableArray *paths = [NSMutableArray array];

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
            // -m 只取后面两个路径
            if (i + 1 < argc && argv[i+1][0] == '/') {
                char buf[PATH_MAX];
                strlcpy(buf, argv[++i], sizeof(buf));
                strip_trailing_slash(buf);
                strip_rootfs_prefix(buf);
                map_src = @(buf);
            }
            if (i + 1 < argc && argv[i+1][0] == '/') {
                char buf[PATH_MAX];
                strlcpy(buf, argv[++i], sizeof(buf));
                strip_trailing_slash(buf);
                strip_rootfs_prefix(buf);
                map_dst = @(buf);
            }
            // 丢弃后续参数
            break;
        } else if (argv[i][0] == '/') {
            char buf[PATH_MAX];
            strlcpy(buf, argv[i], sizeof(buf));
            strip_trailing_slash(buf);
            strip_rootfs_prefix(buf);
            [paths addObject:@(buf)];
        } else {
            fprintf(stderr, "Error: invalid argument %s\n", argv[i]);
            return 2;
        }
    }

    NSMutableDictionary *prefs = [load_prefs() mutableCopy] ?: [NSMutableDictionary dictionary];

    // ---------- -l 列出路径 ----------
    if (is_list) {
        NSArray *arr = prefs[@"path"];
        if (!arr.count) {
            printf("You have not set any folder for automatic mount.\n");
        } else {
            for (NSString *p in arr) printf("%s\n", p.UTF8String);
        }
        return 0;
    }

    // ---------- -s 设置路径 ----------
    if (is_set) {
        prefs[@"Enable"] = @YES;
        if (!prefs[@"root"]) prefs[@"root"] = @(DEFAULT_MOUNT_BASE);

        NSMutableArray *arr = [NSMutableArray arrayWithArray:prefs[@"path"] ?: @[]];

        if (set_mode == 1) {
            // --add：追加
            for (NSString *p in paths) {
                const char *converted = rootfs(p.UTF8String);
                char resolved[PATH_MAX];
                NSString *clean = p;
                if (realpath(converted, resolved)) {
                    strip_trailing_slash(resolved);
                    clean = @(resolved);
                }
                if (![arr containsObject:clean]) [arr addObject:clean];
            }
        } else if (set_mode == 2) {
            // --del：删除
            for (NSString *p in paths) {
                const char *converted = rootfs(p.UTF8String);
                char resolved[PATH_MAX];
                NSString *clean = p;
                if (realpath(converted, resolved)) {
                    strip_trailing_slash(resolved);
                    clean = @(resolved);
                }
                [arr removeObject:clean];
            }
        } else {
            // 默认：覆盖
            [arr removeAllObjects];
            for (NSString *p in paths) {
                const char *converted = rootfs(p.UTF8String);
                char resolved[PATH_MAX];
                if (realpath(converted, resolved)) {
                    strip_trailing_slash(resolved);
                    [arr addObject:@(resolved)];
                } else {
                    [arr addObject:p];
                }
            }
        }

        prefs[@"path"] = arr;
        BOOL ok = save_prefs(prefs);
        printf("%s\n", ok ? "status: Success" : "status: Failure");
        if (ok) {
            printf("Automatic mount list:\n");
            for (NSString *p in arr) printf("%s\n", p.UTF8String);
        }
        return ok ? 0 : 1;
    }

    // ---------- --auto ----------
    if (is_auto) {
        if (access(jbroot("/basebin/.safe_mode"), F_OK) == 0) return 0;
        if (access(rootfs("/var/mobile/.not_auto_mount"), F_OK) == 0) return 0;
        if (![prefs[@"Enable"] boolValue]) return 0;

        NSArray *arr = prefs[@"path"];
        if (!arr.count) return 0;
        [paths addObjectsFromArray:arr];
        is_mount = 1;
    }

    // ---------- --prefs mount ----------
    if (is_prefs_mount) {
        NSArray *arr = prefs[@"path"];
        if (!arr.count) {
            printf("No paths configured.\n");
            return 0;
        }
        [paths addObjectsFromArray:arr];
        is_mount = 1;
    }

    if (!is_mount && !is_unmount) {
        // 没有 -m/-u 时，有路径就当作批量挂载
        if (paths.count) {
            is_mount = 1;
        } else {
            print_usage();
            return 1;
        }
    }

    if (!paths.count && !map_src) {
        print_usage();
        return 1;
    }

    // ---------- 计算挂载基路径 ----------
    NSString *mount_to_base = prefs[@"root"] ?: @(DEFAULT_MOUNT_BASE);
    char mount_base[PATH_MAX];

    if ([mount_to_base isEqualToString:@".jbroot"]) {
        strlcpy(mount_base, jbroot("/"), sizeof(mount_base));
    } else if ([mount_to_base hasPrefix:@".jbroot/"]) {
        NSString *suffix = [mount_to_base substringFromIndex:7];
        strlcpy(mount_base, jbroot(suffix.UTF8String), sizeof(mount_base));
    } else if ([mount_to_base hasPrefix:@"/"]) {
        strlcpy(mount_base, mount_to_base.UTF8String, sizeof(mount_base));
    } else {
        strlcpy(mount_base, jbroot(mount_to_base.UTF8String), sizeof(mount_base));
    }
    strip_trailing_slash(mount_base);

    // 创建 .bindfs 符号链接
    unlink(jbroot("/.bindfs"));
    symlink(mount_base, jbroot("/.bindfs"));

    // ---------- -m 指定一对一映射（直接用真实路径，不用 jbroot 拼） ----------
    if (is_mount && map_src && map_dst) {
        char src_buf[PATH_MAX], dst_buf[PATH_MAX];
        strlcpy(src_buf, map_src.UTF8String, sizeof(src_buf));
        strlcpy(dst_buf, map_dst.UTF8String, sizeof(dst_buf));
        strip_trailing_slash(src_buf);
        strip_trailing_slash(dst_buf);
        strip_rootfs_prefix(src_buf);
        strip_rootfs_prefix(dst_buf);

        printf("Will mount \"%s\" -> \"%s\"\n", src_buf, dst_buf);

        NSFileManager *fm = [NSFileManager defaultManager];
        BOOL need_copy = (copy_mode == 1);
        if (copy_mode == 0) {
            BOOL isDir = NO;
            if (![fm fileExistsAtPath:@(dst_buf) isDirectory:&isDir] || !isDir) need_copy = YES;
            else {
                NSArray *c = [fm contentsOfDirectoryAtPath:@(dst_buf) error:nil];
                if (!c.count) need_copy = YES;
            }
        }
        if (need_copy) {
            NSError *err = nil;
            if ([fm fileExistsAtPath:@(dst_buf)]) [fm removeItemAtPath:@(dst_buf) error:nil];
            // 先创建父目录
            NSString *parent = [@(dst_buf) stringByDeletingLastPathComponent];
            [fm createDirectoryAtPath:parent withIntermediateDirectories:YES attributes:nil error:nil];
            if (![fm copyItemAtPath:@(src_buf) toPath:@(dst_buf) error:&err]) {
                printf("status: Failure\nLog: copy failed: %s\n", err.localizedDescription.UTF8String ?: "unknown");
                return 1;
            }
        } else if (copy_mode == 2) {
            [fm createDirectoryAtPath:@(dst_buf) withIntermediateDirectories:YES attributes:nil error:nil];
        }
        // 直接用真实路径挂载
        if (do_mount(src_buf, dst_buf) != 0) {
            printf("status: Failure\nLog: mount failed\n");
            return 1;
        }
        printf("status: Success\n");
        return 0;
    }

    // ---------- fork 子进程并发处理 ----------
    NSMutableArray *pids = [NSMutableArray array];

    for (NSString *pathStr in paths) {
        pid_t pid = fork();
        if (pid == 0) {
            int ret = handle_one_path(pathStr, mount_base, copy_mode, is_unmount);
            _exit(ret);
        } else if (pid > 0) {
            [pids addObject:@(pid)];
        } else {
            perror("fork failed");
            return 1;
        }
    }

    int exit_status = 0;
    int mounted_count = 0;  // 真正新挂载的数量
    for (NSNumber *pidNum in pids) {
        int status = 0;
        waitpid(pidNum.intValue, &status, 0);
        if (WIFEXITED(status)) {
            int code = WEXITSTATUS(status);
            if (code == 0) mounted_count++;  // 真正挂载成功
            else if (code != 2) exit_status = 1;  // 2 是跳过，不算失败
        } else {
            exit_status = 1;
        }
    }

    // 自动模式：至少有一个真正新挂载才生效
    if (is_auto && exit_status == 0 && mounted_count > 0) {
        // 从 prefs 读取重启方式
        NSString *prefsPath = @(jbroot(PREFS_PATH));
        NSDictionary *p = [NSDictionary dictionaryWithContentsOfFile:prefsPath];
        int mode = p[@"reboot"] ? [p[@"reboot"] intValue] : 1;
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

    return exit_status;
}
