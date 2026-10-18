//
//  main.m
//  Cyanide
//
//  Created by seo on 3/24/26.
//

#import <UIKit/UIKit.h>
#import "AppDelegate.h"
#if DEBUG
#include <fcntl.h>
#include <string.h>
#include <unistd.h>
#endif

#if DEBUG
// Debug-only launch marker: written at the very first line of main, before any
// argv check, by every Debug launch. The self proof reads the child's marker
// through launchd root read. This distinguishes "child never reached main"
// (no marker) from "child ran but could not write the app-container output".
static void cyanide_debug_root_child_marker(int argc, char **argv) {
    char path[160];
    snprintf(path, sizeof(path), "/private/var/tmp/cyanide-root-child-%d.txt", getpid());
    int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (fd < 0) return;
    char buf[320];
    int n = snprintf(buf, sizeof(buf),
                     "pid=%d ppid=%d uid=%u euid=%u gid=%u argc=%d arg1=%s\n",
                     getpid(), getppid(), (unsigned)getuid(), (unsigned)geteuid(),
                     (unsigned)getgid(), argc,
                     (argc > 1 && argv[1]) ? argv[1] : "-");
    if (n > 0) (void)write(fd, buf, (size_t)n);
    close(fd);
}
#endif

#if DEBUG
// Debug-only launchd root-exec child: the launchd proof spawns this same app
// executable with this flag and an output path. We run BEFORE UIKit and exit
// immediately, writing the real uid/euid/gid. It is never compiled into
// Release.
static void cyanide_debug_root_exec_child(int argc, char *argv[]) {
    if (argc < 3 || strcmp(argv[1], "--cyanide-root-exec-child") != 0) return;
    int fd = open(argv[2], O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (fd >= 0) {
        char buf[256];
        int n = snprintf(buf, sizeof(buf), "uid=%u euid=%u gid=%u pid=%d\n",
                         (unsigned)getuid(), (unsigned)geteuid(),
                         (unsigned)getgid(), getpid());
        if (n > 0) (void)write(fd, buf, (size_t)n);
        close(fd);
    }
    _exit(fd >= 0 ? 0 : 1);
}
#endif

int main(int argc, char * argv[]) {
#if DEBUG
    cyanide_debug_root_child_marker(argc, argv);
    if (argc >= 3 && strcmp(argv[1], "--cyanide-root-exec-child") == 0)
        cyanide_debug_root_exec_child(argc, argv);
#endif
    // Round 31: FIRST executable statement — before UIApplicationMain, before
    // any app code. If the black-screen-with-no-headers failure reproduces,
    // this line existing (with a NEW pid) proves a fresh process spawned and
    // the wedge is later; its absence proves SpringBoard never spawned one.
    cyanide_launch_trace("main: entry");
    NSString * appDelegateClassName;
    @autoreleasepool {
        // Setup code that might create autoreleased objects goes here.
        appDelegateClassName = NSStringFromClass([AppDelegate class]);
    }
    return UIApplicationMain(argc, argv, nil, appDelegateClassName);
}
