#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

docker run --rm --pull never --network none --read-only --cap-drop=ALL \
  --security-opt=no-new-privileges --tmpfs /tmp:rw,exec,size=512m \
  -e RMW_IMPLEMENTATION=rmw_fastrtps_cpp -e ROS_DOMAIN_ID=187 \
  -e ROS_HOME=/tmp/ros -e OVCS_NAV2_TEST_CONTAINER=1 \
  --mount "type=bind,src=$(cd .. && pwd),dst=/review,readonly" \
  --mount "type=bind,src=$PWD,dst=/opt/ovcs/config,readonly" \
  --entrypoint /bin/bash ovcs/nav2:lyrical \
  -c 'source /opt/ros/lyrical/setup.bash && python3 /opt/ovcs/config/test_runtime.py'
