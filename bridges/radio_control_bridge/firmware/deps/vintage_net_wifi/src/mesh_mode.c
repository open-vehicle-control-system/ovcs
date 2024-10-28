/*
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#include <err.h>
#include <stdlib.h>
#include <unistd.h>

#include <net/if.h>
#include <netlink/genl/genl.h>
#include <netlink/genl/ctrl.h>

#include <linux/nl80211.h>

/**
 * Create a virtual mesh interface from a real interface.
 *
 */
int main(int argc, char **argv)
{
    if (argc != 4)
        errx(EXIT_FAILURE, "Specify a WiFi network device and the name of the mesh interface");

    uint32_t ifindex = if_nametoindex(argv[1]);
    if (ifindex == 0)
        errx(EXIT_FAILURE, "Specify a WiFi device that works: %s", argv[1]);

    char *name = argv[2];
    char *cmd = argv[3];

    struct nl_sock *nl_sock = nl_socket_alloc();
    if (!nl_sock)
        err(EXIT_FAILURE, "nl_socket_alloc");

    if (genl_connect(nl_sock))
        err(EXIT_FAILURE, "genl_connect");

    int nl80211_id = genl_ctrl_resolve(nl_sock, "nl80211");
    if (nl80211_id < 0)
        err(EXIT_FAILURE, "genl_ctrl_resolve(nl80211)");

    struct nl_msg *msg = nlmsg_alloc();
    if (!msg)
        err(EXIT_FAILURE, "nlmsg_alloc");

    uint32_t data;
    
    // msg, port, seq, family, hdrlen, flags, cmd, version
    if(strcmp(cmd, "add") == 0) {
        data = ifindex;
        genlmsg_put(msg, 0, 0, nl80211_id, 0, 0, NL80211_CMD_NEW_INTERFACE, 0);
    } else if(strcmp(cmd, "del") == 0) {
        data = if_nametoindex(name);
        genlmsg_put(msg, 0, 0, nl80211_id, 0, 0, NL80211_CMD_DEL_INTERFACE, 0);
    } else {
        err(EXIT_FAILURE, "unknown cmd %s", cmd);
    }

    nla_put(msg, NL80211_ATTR_IFINDEX, sizeof(data), &data);

    nla_put_string(msg, NL80211_ATTR_IFNAME, name);

    data = NL80211_IFTYPE_MESH_POINT;
    nla_put(msg, NL80211_ATTR_IFTYPE, sizeof(data), &data);

    if (nl_send_auto(nl_sock, msg) < 0)
        err(EXIT_FAILURE, "nl_send_auto");

    nlmsg_free(msg);
    nl_socket_free(nl_sock);
    return 0;
}
