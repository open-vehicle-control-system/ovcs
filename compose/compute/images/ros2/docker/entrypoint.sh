#!/usr/bin/env bash
# Shared ENTRYPOINT for every ROS 2 image in this compose stack.
#
# Reads the distribution from ROS_DISTRO, which the base image sets,
# rather than naming it — so a distro bump is a change to the FROM
# line and nothing else.
# Does only the cross-cutting setup every service needs:
#   1. Render the Zenoh session config from its template.
#   2. Source the ROS 2 Lyrical overlay so `ros2 …` works.
# Then `exec`s whatever CMD (or `docker run …` override) was passed —
# i.e. it is service-agnostic. Per-service launch logic lives in CMD,
# not here.
#
# With ZENOH_ROUTER_ADMIN_URL set, the CMD runs under a router watch
# instead of a plain exec. A rmw_zenoh_cpp node declares its topics to
# the router it joined; when that router *process* is replaced — the
# container recreated by a deploy, or a crash and restart — the node's
# session reconnects, but the new router knows nothing of the node and
# the node nothing of the fabric. It looks healthy and sees nothing.
# The router's admin space carries a zid that changes with every
# process, so: wait for the router before launching, then poll the zid
# and exit when it changes; the service's restart policy starts the
# CMD over against the new router. A router that is merely unreachable
# is left to the session's own reconnection.

set -euo pipefail

: "${ZENOH_ENDPOINT_IP:?ZENOH_ENDPOINT_IP must be set}"
: "${ZENOH_SESSION_CONFIG_URI:=/tmp/zenoh-session.json5}"
: "${ZENOH_SESSION_CONFIG_TEMPLATE:=/etc/zenoh/session.json5.template}"

envsubst < "${ZENOH_SESSION_CONFIG_TEMPLATE}" > "${ZENOH_SESSION_CONFIG_URI}"
export ZENOH_SESSION_CONFIG_URI

# ROS 2's setup.bash references AMENT_TRACE_SETUP_FILES without a
# default, so it trips `set -u`. Drop nounset just for the source.
set +u
# shellcheck disable=SC1091
source "/opt/ros/${ROS_DISTRO}/setup.bash"
set -u

if [[ -z "${ZENOH_ROUTER_ADMIN_URL:-}" ]]; then
  exec "$@"
fi

: "${ZENOH_ROUTER_WATCH_INTERVAL:=5}"

# The router's zid, or nothing when it does not answer as a router.
# Never fails: an empty answer is the signal, not an error, and this
# runs under `set -e`.
router_zid() {
  curl --silent --fail --max-time 2 "${ZENOH_ROUTER_ADMIN_URL%/}/@/local/router" 2>/dev/null \
    | grep --only-matching '"zid": *"[0-9a-f]*"' | head -n 1 | cut -d '"' -f 4 || true
}

zid="$(router_zid)"
if [[ -z "${zid}" ]]; then
  echo "entrypoint: waiting for the Zenoh router at ${ZENOH_ROUTER_ADMIN_URL}"
  until zid="$(router_zid)" && [[ -n "${zid}" ]]; do
    sleep "${ZENOH_ROUTER_WATCH_INTERVAL}"
  done
fi
echo "entrypoint: Zenoh router ${zid} is up"

"$@" &
child=$!
stopping=""
# A stop of the service is a stop of the CMD, not a router event.
trap 'stopping=1; kill -TERM "${child}" 2>/dev/null' TERM INT

while kill -0 "${child}" 2>/dev/null; do
  sleep "${ZENOH_ROUTER_WATCH_INTERVAL}" &
  wait $! || true
  [[ -n "${stopping}" ]] && continue
  current="$(router_zid)"
  if [[ -n "${current}" && "${current}" != "${zid}" ]]; then
    echo "entrypoint: Zenoh router replaced (${zid} -> ${current}); restarting $1"
    kill -TERM "${child}" 2>/dev/null
    for _ in $(seq 1 20); do
      kill -0 "${child}" 2>/dev/null || break
      sleep 0.5
    done
    kill -KILL "${child}" 2>/dev/null || true
    wait "${child}" 2>/dev/null || true
    exit 1
  fi
done

wait "${child}"
