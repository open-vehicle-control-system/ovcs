#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <arpa/inet.h>
#include <net/if_arp.h>
#include <sys/ioctl.h>

int main(int argc, char *argv[])
{
    if (argc != 4) {
        printf("%s <ifname> <ip> <hwaddr>\n", argv[0]);
        exit(EXIT_FAILURE);
    }

#ifndef __APPLE__
    const char *ifname = argv[1];
#endif
    const char *ip = argv[2];
    const char *hwaddr_str = argv[3];

    char hwaddr[6];
    if (sscanf(hwaddr_str, "%2hhx:%2hhx:%2hhx:%2hhx:%2hhx:%2hhx",
               &hwaddr[0], &hwaddr[1], &hwaddr[2], &hwaddr[3], &hwaddr[4], &hwaddr[5]) != 6) {
        printf("Couldn't parse mac address '%s'\n", hwaddr_str);
        exit(EXIT_FAILURE);
    }

    struct arpreq arp;
    memset(&arp, 0, sizeof(arp));

    struct sockaddr_in *sa = (struct sockaddr_in *) &arp.arp_pa;
    sa->sin_family = AF_INET;
    if (inet_pton(AF_INET, ip, &sa->sin_addr) <= 0) {
        printf("Couldn't parse IPv4 address '%s'\n", ip);
        exit(EXIT_FAILURE);
    }
    arp.arp_ha.sa_family = ARPHRD_ETHER;
    memcpy(&arp.arp_ha.sa_data, hwaddr, 6);

    arp.arp_flags = ATF_COM;
#ifndef __APPLE__
    strncpy(arp.arp_dev, ifname, sizeof(arp.arp_dev) - 1);

    int s = socket(AF_INET, SOCK_DGRAM, 0);
    if (ioctl(s, SIOCSARP, &arp) < 0) {
        printf("SIOCSARP failed: %s\n", strerror(errno));
        exit(EXIT_FAILURE);
    }
    exit(EXIT_SUCCESS);
#else
    printf("SIOCSARP not supported on OSX\n");
    exit(EXIT_FAILURE);
#endif
}

