/*
 * origdst_test.c -- check that getsockopt(fd, SOL_IP, SO_ORIGINAL_DST, ...)
 * is actually forwarded to the kernel when the program runs under
 * qemu-x86_64.
 *
 * The socket must be one that netfilter redirected, otherwise the kernel
 * has no conntrack entry to report.  Run with NET_ADMIN and:
 *
 *   iptables -t nat -A OUTPUT -p tcp -d 127.0.0.1 --dport 18081 \
 *            -j REDIRECT --to-ports 18080
 *
 * Exit status: 0 = PASS, 2 = getsockopt failed, 3 = wrong address reported.
 */
#include <arpa/inet.h>
#include <errno.h>
#include <netinet/in.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

#ifndef SO_ORIGINAL_DST
#define SO_ORIGINAL_DST 80
#endif

#define LISTEN_PORT 18080
#define ORIG_PORT   18081

static int make_listener(void)
{
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    int one = 1;
    struct sockaddr_in a;

    if (fd < 0) {
        perror("socket");
        return -1;
    }
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));

    memset(&a, 0, sizeof(a));
    a.sin_family = AF_INET;
    a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    a.sin_port = htons(LISTEN_PORT);
    if (bind(fd, (struct sockaddr *)&a, sizeof(a)) < 0 ||
        listen(fd, 1) < 0) {
        perror("bind/listen");
        close(fd);
        return -1;
    }
    return fd;
}

int main(void)
{
    int lfd, cfd, afd;
    struct sockaddr_in d, od;
    socklen_t ol;
    char buf[INET_ADDRSTRLEN];
    int ret;

    lfd = make_listener();
    if (lfd < 0) {
        return 1;
    }

    cfd = socket(AF_INET, SOCK_STREAM, 0);
    memset(&d, 0, sizeof(d));
    d.sin_family = AF_INET;
    d.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    d.sin_port = htons(ORIG_PORT);
    if (connect(cfd, (struct sockaddr *)&d, sizeof(d)) < 0) {
        perror("connect");
        return 1;
    }

    afd = accept(lfd, NULL, NULL);
    if (afd < 0) {
        perror("accept");
        return 1;
    }

    memset(&od, 0, sizeof(od));
    ol = sizeof(od);
    errno = 0;
    ret = getsockopt(afd, SOL_IP, SO_ORIGINAL_DST, &od, &ol);
    if (ret < 0) {
        printf("FAIL: getsockopt(SOL_IP, SO_ORIGINAL_DST) errno=%d (%s)\n",
               errno, strerror(errno));
        return 2;
    }

    inet_ntop(AF_INET, &od.sin_addr, buf, sizeof(buf));
    printf("getsockopt(SOL_IP, SO_ORIGINAL_DST) -> %s:%u "
           "(family=%d, optlen=%u)\n",
           buf, (unsigned)ntohs(od.sin_port), od.sin_family, (unsigned)ol);

    if (ntohs(od.sin_port) != ORIG_PORT) {
        printf("FAIL: expected original destination port %d\n", ORIG_PORT);
        return 3;
    }

    printf("PASS\n");
    return 0;
}
