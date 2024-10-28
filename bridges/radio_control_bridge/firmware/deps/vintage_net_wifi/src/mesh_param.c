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
 * useage: mesh_param meshifname param value
 *
 */
int main(int argc, char **argv)
{
    if (argc != 4)
        errx(EXIT_FAILURE, "Specify a WiFi network device, a param and a value");

    uint32_t ifindex = if_nametoindex(argv[1]);
    if (ifindex == 0)
        errx(EXIT_FAILURE, "Specify a WiFi device that works: %s", argv[1]);

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

    char *param = argv[2];
    char *param_value = argv[3];

    uint8_t data;
    struct nlattr *container;
    uint32_t ret;
    enum nl80211_meshconf_params cmd;

    if(strcmp(param, "mesh_hwmp_rootmode") == 0) {
      cmd = NL80211_MESHCONF_HWMP_ROOTMODE;
      data = strtol(param_value, NULL, 10);

    } else if(strcmp(param, "mesh_gate_announcements") == 0) {
      cmd = NL80211_MESHCONF_GATE_ANNOUNCEMENTS;
      data = strtol(param_value, NULL, 10);

    } else {
      err(EXIT_FAILURE, "unknown mesh param %s", param);
    }
    
    // msg, port, seq, family, hdrlen, flags, cmd, version
    genlmsg_put(msg, 0, 0, nl80211_id, 0, 0, NL80211_CMD_SET_MESH_PARAMS, 0);

    // Tell nl which interface we are using
    nla_put(msg, NL80211_ATTR_IFINDEX, sizeof(ifindex), &ifindex);

    // container for nested attrs
    container = nla_nest_start(msg, NL80211_ATTR_MESH_PARAMS);
    if (!container)
      err(EXIT_FAILURE, "nla_nest_start");

    ret = nla_put(msg, cmd, sizeof(uint8_t), &data);
    if(ret)
      err(EXIT_FAILURE, "nla_put");

	  nla_nest_end(msg, container);
    
    if (nl_send_auto(nl_sock, msg) < 0)
        err(EXIT_FAILURE, "nl_send_auto");

    nlmsg_free(msg);
    nl_socket_free(nl_sock);
    return 0;
}
