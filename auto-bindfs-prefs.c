#import <unistd.h>
#import <stdio.h>
#import <stdlib.h>
#import <string.h>
#import <sys/wait.h>
#include <roothide.h>

int main(int argc, char *argv[]) {
    if (setuid(0) != 0) {
        perror("setuid failed");
        return 1;
    }
    if (setgid(0) != 0) {
        perror("setgid failed");
        return 1;
    }

    const char *bin = jbroot("/usr/sbin/mount_bindfs");
    
    if (argc > 1 && !strcmp(argv[1], "mount")) {
        // 立即挂载
        execl(bin, "mount_bindfs", "--prefs", "mount", NULL);
    } else if (argc > 2 && !strcmp(argv[1], "reboot")) {
        // 直接处理重启
        int mode = atoi(argv[2]);
        if (mode == 2) {
            pid_t pid = fork();
            if (pid == 0) {
                execl(jbroot("/usr/bin/killall"), "killall", "-9", "cfprefsd", NULL);
                _exit(0);
            }
            waitpid(pid, NULL, 0);
            execl(jbroot("/usr/bin/killall"), "killall", "-9", "backboardd", NULL);
        } else {
            execl(jbroot("/usr/bin/launchctl"), "launchctl", "reboot", "userspace", NULL);
        }
    }
    perror("execl failed");
    return 1;
}
