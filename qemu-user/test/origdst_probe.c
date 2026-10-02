/*
 * origdst_probe.c -- minimal A/B probe, needs no privileges.
 *
 * The kernel implements SO_ORIGINAL_DST in nf_nat_ipv4_getsockopt() and
 * returns -ENOENT when there is no conntrack entry to report.  An emulator
 * that does not know the option answers -ENOPROTOOPT instead, so the errno
 * alone tells us whether the option reached the kernel.
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

int main(void)
{
    struct sockaddr_in a, od;
    socklen_t ol = sizeof(od);
    int s, r;

    s = socket(AF_INET, SOCK_STREAM, 0);
    if (s < 0) {
        perror("socket");
        return 1;
    }

    memset(&a, 0, sizeof(a));
    a.sin_family = AF_INET;
    a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    a.sin_port = htons(1);
    connect(s, (struct sockaddr *)&a, sizeof(a)); /* may fail, that is fine */

    errno = 0;
    memset(&od, 0, sizeof(od));
    r = getsockopt(s, SOL_IP, SO_ORIGINAL_DST, &od, &ol);
    printf("getsockopt(SOL_IP, SO_ORIGINAL_DST) = %d, errno = %d (%s)\n",
           r, errno, strerror(errno));

    if (errno == ENOPROTOOPT) {
        printf("RESULT: NOT forwarded (emulator answered ENOPROTOOPT)\n");
        return 2;
    }
    printf("RESULT: forwarded to the kernel\n");
    return 0;
}
