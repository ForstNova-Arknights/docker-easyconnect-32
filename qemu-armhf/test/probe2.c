#include <stdio.h>
#include <errno.h>
#include <string.h>
#include <netinet/in.h>
#include <netinet/ip.h>
#include <sys/socket.h>
#include <unistd.h>
int main(void){
  int s = socket(AF_INET, SOCK_STREAM, 0);
  int v=0; socklen_t l=sizeof v; int r;
  errno=0; r=getsockopt(s, SOL_IP, IP_TTL, &v, &l);
  printf("IP_TTL(2): r=%d v=%d errno=%d(%s)\n", r, v, errno, strerror(errno));
  struct sockaddr_in od; socklen_t ol=sizeof od;
  errno=0; r=getsockopt(s, SOL_IP, 80, &od, &ol);
  printf("optname 80: r=%d errno=%d(%s)\n", r, errno, strerror(errno));
  errno=0; r=getsockopt(s, 0, 999, &od, &ol);
  printf("optname 999: r=%d errno=%d(%s)\n", r, errno, strerror(errno));
  return 0;
}
