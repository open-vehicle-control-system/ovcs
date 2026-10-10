#!/bin/sh
# Ensure the rule is present, then keep it present: NetworkManager
# rewrites its own nat rules whenever the shared connection is
# re-activated, and a reboot starts from nothing. Checking every 30 s
# with -C is free; the rule is only ever inserted when missing.
set -eu

BRIDGE="${BRIDGE_IFACE:-ovcs0}"
RULE="POSTROUTING -o $BRIDGE -m comment --comment ovcs-bridge-no-nat -j ACCEPT"

while :; do
  if ! iptables-legacy -t nat -C $RULE 2>/dev/null; then
    if iptables-legacy -t nat -I $RULE 2>/dev/null; then
      echo "inserted: traffic leaving through $BRIDGE is exempt from NAT"
    else
      echo "cannot edit the nat table; not privileged, or $BRIDGE does not exist yet"
    fi
  fi
  sleep 30
done
