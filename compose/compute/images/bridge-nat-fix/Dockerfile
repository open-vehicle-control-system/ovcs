# Keeps NetworkManager's NAT off traffic that never leaves the vehicle
# bridge. See ../../host/README.md for the network this belongs to.
#
# balena-engine turns on `net.bridge.bridge-nf-call-iptables`, so every
# frame the ovcs0 bridge forwards between eth0 and the access point is
# run through iptables as if it were routed. The `method=shared` bridge
# carries a MASQUERADE rule for anything not addressed to 10.42.0.0/24,
# and a multicast destination (224.0.0.251 for mDNS, 255.255.255.255 for
# a DHCP broadcast) is exactly that: a laptop's mDNS query leaves eth0
# with the bridge's own address and a random source port, a board
# answers it as a legacy unicast query, and the laptop's resolver — as
# RFC 6762 requires — discards a reply that did not come from port 5353.
# The result is `ovcs-mini-vms.local` resolving from the site Wi-Fi but
# not from the vehicle's own access point.
#
# The per-bridge `nf_call_iptables` knob cannot switch this off while the
# global sysctl is on, and turning the global one off would change how
# the engine isolates its own container networks. So the fix is one NAT
# rule, ahead of NetworkManager's: what leaves through ovcs0 stays as it
# is. iptables-legacy because the host's iptables is the legacy backend
# (`iptables -V` on the host) and both must edit the same tables.
FROM alpine:3.22

# iptables-legacy is the binary; the match extensions it loads (the
# `comment` match the rule is tagged with) ship in the iptables package.
RUN apk add --no-cache iptables iptables-legacy

COPY entrypoint.sh /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
