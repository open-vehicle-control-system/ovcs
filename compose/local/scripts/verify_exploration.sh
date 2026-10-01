#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

REPO="$(cd ../../.. && pwd)"
: "${NAV2_TEST_IMAGE:=ovcs/nav2:offline-test}"
: "${SKIP_BUILD:=0}"
: "${RESULT_DIR:=$(mktemp -d /tmp/ovcs-exploration.XXXXXX)}"
mkdir -p "$RESULT_DIR"

step() { printf '\n\033[1;36m==> %s\033[0m\n' "$1"; }
if [[ "$SKIP_BUILD" != 1 ]]; then
  step "Building Nav2 and the exploration guard"
  docker build -t "$NAV2_TEST_IMAGE" -f "$REPO/compose/compute/images/nav2/Dockerfile" "$REPO/compose/compute"
fi

run_case() {
  local name="$1"
  shift
  step "$name"
  mkdir -p "$RESULT_DIR/$name"
  docker run --rm --network none --entrypoint bash \
    -e RMW_IMPLEMENTATION=rmw_zenoh_cpp -e PYTHONDONTWRITEBYTECODE=1 \
    -v "$REPO/compose/compute/nav2/launch:/opt/ovcs/launch:ro" \
    -v "$REPO/compose/compute/nav2/config:/opt/ovcs/config:ro" \
    -v "$REPO/compose/compute/explore/forward_explore:/opt/ovcs/forward_explore:ro" \
    -v "$REPO/compose/local/simulation/scripts:/test:ro" \
    -v "$RESULT_DIR/$name:/tmp" "$NAV2_TEST_IMAGE" -c \
    'set -e; source /opt/ros/lyrical/setup.bash; source /opt/ovcs/nav2_overlay/setup.bash; ros2 run rmw_zenoh_cpp rmw_zenohd > /tmp/router.log 2>&1 & python3 /test/exploration_test.py "$@"' bash "$@" \
    | tee "$RESULT_DIR/$name/result.json"
}

for scenario in open corridor dead_end; do
  run_case "$scenario" --scenario "$scenario"
done
for fault in cloud odom tf map explorer; do
  run_case "loss-$fault" --fault "$fault" --duration 80
done
run_case retreat-loss-cloud --scenario dead_end --fault cloud --during-retreat --duration 80
run_case retreat-loss-explorer --scenario dead_end --fault explorer --during-retreat --duration 80
printf '\nOffline exploration results: %s\n' "$RESULT_DIR"
