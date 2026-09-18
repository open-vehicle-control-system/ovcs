#!/usr/bin/env bash
# Run on the balenaOS host after deploying wifi_ap_fix.
set -euo pipefail

if [ -z "$(balena-engine ps -q --filter name=wifi_ap_fix)" ]; then
  echo "Deploy and start wifi_ap_fix before configuring the AP" >&2
  exit 1
fi

backup=/mnt/data/ovcs-ap-before-5ghz
mkdir -p "$backup"
chmod 700 "$backup"
if [ ! -f "$backup/ovcs0-ap.nmconnection" ]; then
  cp /mnt/boot/system-connections/ovcs0-ap.nmconnection "$backup/ovcs0-ap.nmconnection"
  chmod 600 "$backup/ovcs0-ap.nmconnection"
fi
if ! nmcli -g connection.id connection show ovcs0-ap-fallback >/dev/null 2>&1; then
  nmcli connection clone ovcs0-ap ovcs0-ap-fallback
fi
nmcli connection modify ovcs0-ap-fallback connection.autoconnect yes \
  connection.autoconnect-priority -100 connection.autoconnect-retries 1 \
  802-11-wireless.band bg 802-11-wireless.channel 11 802-11-wireless.channel-width 20
fallback_uuid=$(nmcli -g connection.uuid connection show ovcs0-ap-fallback)
fallback_file=$(grep -l "^uuid=$fallback_uuid$" /etc/NetworkManager/system-connections/*)
cp "$fallback_file" /mnt/boot/system-connections/ovcs0-ap-fallback.nmconnection
chmod 600 /mnt/boot/system-connections/ovcs0-ap-fallback.nmconnection
nmcli connection modify ovcs0-ap connection.autoconnect yes \
  connection.autoconnect-priority 100 connection.autoconnect-retries 1 \
  802-11-wireless.band a 802-11-wireless.channel 149 802-11-wireless.channel-width 80
preferred_uuid=$(nmcli -g connection.uuid connection show ovcs0-ap)
preferred_file=$(grep -l "^uuid=$preferred_uuid$" /etc/NetworkManager/system-connections/*)
cp "$preferred_file" /mnt/boot/system-connections/ovcs0-ap.nmconnection
chmod 600 /mnt/boot/system-connections/ovcs0-ap.nmconnection
sync
printf 'Persistent AP and fallback profiles installed\n'
