#!/usr/bin/env bash
# Shared ENTRYPOINT for every ROS 2 image in this compose stack.
# Does only the cross-cutting setup every service needs:
#   1. Render the Zenoh session config from its template.
#   2. Source the ROS 2 Jazzy overlay so `ros2 …` works.
# Then `exec`s whatever CMD (or `docker run …` override) was passed —
# i.e. it is service-agnostic. Per-service launch logic lives in CMD,
# not here.

set -euo pipefail

: "${ZENOH_ENDPOINT_IP:?ZENOH_ENDPOINT_IP must be set}"
: "${ZENOH_SESSION_CONFIG_URI:=/tmp/zenoh-session.json5}"
: "${ZENOH_SESSION_CONFIG_TEMPLATE:=/etc/zenoh/session.json5.template}"

envsubst < "${ZENOH_SESSION_CONFIG_TEMPLATE}" > "${ZENOH_SESSION_CONFIG_URI}"
export ZENOH_SESSION_CONFIG_URI

# ROS 2 Jazzy's setup.bash references AMENT_TRACE_SETUP_FILES without a
# default, so it trips `set -u`. Drop nounset just for the source.
set +u
# shellcheck disable=SC1091
source /opt/ros/jazzy/setup.bash
set -u

exec "$@"
