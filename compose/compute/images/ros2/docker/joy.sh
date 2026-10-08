#!/usr/bin/env bash
# CMD for the joy image. Reads a USB game controller from ${JOY_DEV}
# (bind-mounted from the host's /dev/input) and publishes
# `sensor_msgs/Joy` on /joy/<profile> via `joy_linux/joy_node`, where
# <profile> is the joy profile in ${JOY_PROFILES} whose `device`
# matches the controller's name, or ${JOY_PROFILE} when set. The ROS
# bridge maps each topic with its profile. A profile's `centring` holds
# a force-feedback spring on the controller (joy_centring). Runs under the shared
# entrypoint, which has already prepared Zenoh + sourced the ROS
# overlay.

set -euo pipefail

: "${JOY_DEV:=/dev/input/js0}"
: "${JOY_PROFILES:=/joy_profiles}"
: "${JOY_AUTOREPEAT_RATE:=20.0}"

if [ ! -e "${JOY_DEV}" ]; then
  echo "joy: ${JOY_DEV} not present on host — plug the controller in" >&2
  echo "joy: available devices: $(ls /dev/input/js* 2>/dev/null || echo none)" >&2
  exit 1
fi

device_name=$(cat "/sys/class/input/$(basename "${JOY_DEV}")/device/name" 2>/dev/null || true)

# Prints the profile's name, its deadzone (0.05 unless it sets one) and
# its centring (0, none, unless it sets one).
read -r profile deadzone centring < <(python3 - "${JOY_PROFILES}" "${device_name}" "${JOY_PROFILE:-}" <<'EOF'
import glob, os, re, sys, yaml

directory, device, wanted = sys.argv[1:4]
profiles = {}
for path in sorted(glob.glob(os.path.join(directory, "*.yml"))):
    with open(path) as f:
        profiles[os.path.splitext(os.path.basename(path))[0]] = yaml.safe_load(f) or {}

if wanted:
    names = [wanted]
else:
    names = [n for n, p in profiles.items() if p.get("device") and re.search(p["device"], device)]

if len(names) != 1:
    found = ", ".join(names) or "none"
    sys.exit(f"joy: {found} of {', '.join(profiles) or 'no profiles'} match {device!r}; set JOY_PROFILE")

profile = profiles.get(names[0], {})
print(names[0], float(profile.get("deadzone", 0.05)), float(profile.get("centring", 0)))
EOF
)
[ -n "${profile:-}" ] || exit 1

if [ "${centring}" != "0.0" ]; then
  joy_centring "${JOY_DEV}" "${centring}" &
fi

echo "joy: ${device_name:-unknown device} on ${JOY_DEV} as profile ${profile} onto /joy/${profile}, peering with ${ZENOH_ENDPOINT_IP}:7447"

exec ros2 run joy_linux joy_linux_node \
  --ros-args \
  -p dev:="${JOY_DEV}" \
  -p deadzone:="${deadzone}" \
  -p autorepeat_rate:="${JOY_AUTOREPEAT_RATE}" \
  -r joy:="joy/${profile}"
