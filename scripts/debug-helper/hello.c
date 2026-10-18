//
//  hello.c — Debug-only nested-helper proof.
//
//  Spawned as root by launchd through the Cyanide Debug proof. It writes its
//  real credentials to the path passed as argv[1] and exits. No UI, no shell,
//  no root-filesystem writes.
//
#include <fcntl.h>
#include <stdio.h>
#include <unistd.h>

int main(int argc, char *argv[]) {
    if (argc < 2 || !argv[1] || !argv[1][0]) return 2;
    int fd = open(argv[1], O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (fd < 0) return 1;
    char buf[256];
    int n = snprintf(buf, sizeof(buf),
                     "hello uid=%u euid=%u gid=%u pid=%d argv0=%s\n",
                     (unsigned)getuid(), (unsigned)geteuid(),
                     (unsigned)getgid(), getpid(),
                     argc > 0 && argv[0] ? argv[0] : "?");
    if (n > 0) (void)write(fd, buf, (size_t)n);
    close(fd);
    return 0;
}
