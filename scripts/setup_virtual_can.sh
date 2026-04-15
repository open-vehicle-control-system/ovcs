#!/usr/bin/env bash
#
# Bring up vcan0..vcan5 for local OVCS development.
#
# Idempotent: if an interface already exists and is UP nothing happens
# and no sudo prompt is triggered. Only the missing/down interfaces are
# touched, and only then is sudo invoked.
#
set -euo pipefail

INTERFACES=(vcan0 vcan1 vcan2 vcan3 vcan4 vcan5)

needs_module() {
  ! lsmod 2>/dev/null | awk '{print $1}' | grep -qx vcan
}

iface_missing() {
  ! ip link show "$1" >/dev/null 2>&1
}

iface_down() {
  [[ "$(ip -br link show "$1" 2>/dev/null | awk '{print $2}')" != "UP" ]]
}

# Dry-run pass: collect work so we can prompt sudo at most once, and skip
# sudo entirely if nothing is needed.
actions=()
needs_module && actions+=("load vcan module")
for iface in "${INTERFACES[@]}"; do
  if iface_missing "$iface"; then
    actions+=("create $iface")
  elif iface_down "$iface"; then
    actions+=("bring up $iface")
  fi
done

if [[ ${#actions[@]} -eq 0 ]]; then
  echo "Virtual CAN interfaces already up — nothing to do."
  exit 0
fi

echo "Will run as root:"
printf "  - %s\n" "${actions[@]}"

sudo bash -c "
  set -e
  if ! lsmod | awk '{print \$1}' | grep -qx vcan; then
    modprobe vcan
  fi
  for iface in ${INTERFACES[*]}; do
    if ! ip link show \"\$iface\" >/dev/null 2>&1; then
      ip link add dev \"\$iface\" type vcan
    fi
    ip link set up \"\$iface\"
  done
"

echo "Virtual CAN interfaces ready: ${INTERFACES[*]}"
echo "Listen: candump -tz vcan0"
echo "Send:   cansend vcan0 123#00FFAA5501020304"
