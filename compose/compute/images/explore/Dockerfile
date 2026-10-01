# Exploration for the vehicle's compute node: forward_explore (in-tree,
# for a car that sees ahead only), and frontier exploration with
# explore_lite from m-explore-ros2, which is not in the ROS archive and
# is built from source at a pinned commit. Same pinned base and snapshot
# as ../nav2/Dockerfile.
FROM ros:lyrical-ros-base@sha256:0c19f326a339ed770ef1d4c0646a8b53bdb49dd5ff74b6de41ebdb8ac21e1806

COPY images/ros2/ros-snapshots.asc /usr/share/keyrings/ros-snapshots.asc
RUN printf '%s\n' \
        'Types: deb' \
        'URIs: http://snapshots.ros.org/lyrical/2026-08-19/ubuntu' \
        'Suites: resolute' \
        'Components: main' \
        'Signed-By: /usr/share/keyrings/ros-snapshots.asc' \
        > /etc/apt/sources.list.d/ros2.sources

# Upgrade first, so the base's packages match the snapshot's: packages
# built against a newer rosidl fail at load with undefined symbols.
RUN apt-get update \
    && apt-get upgrade -y --no-install-recommends \
    && apt-get install -y --no-install-recommends \
        ros-lyrical-rmw-zenoh-cpp \
        ros-lyrical-nav2-costmap-2d \
        ros-lyrical-nav2-msgs \
        ros-lyrical-map-msgs \
        ros-lyrical-visualization-msgs \
        ros-lyrical-tf2-ros-py \
        python3-numpy \
        build-essential \
        cmake \
        curl \
        gettext-base \
    && rm -rf /var/lib/apt/lists/*

ARG M_EXPLORE_COMMIT=326cf8a0b487c34246bb8f3326afbcd69576dc60
RUN mkdir -p /opt/explore/src \
    && curl -fsSL "https://github.com/robo-friends/m-explore-ros2/archive/${M_EXPLORE_COMMIT}.tar.gz" \
        | tar -xz -C /opt/explore/src --strip-components=1 \
    && rm -rf /opt/explore/src/map_merge \
    && cd /opt/explore \
    && . /opt/ros/lyrical/setup.sh \
    && colcon build --merge-install --install-base /opt/explore/install \
        --packages-select explore_lite_msgs explore_lite \
        --cmake-args -DCMAKE_BUILD_TYPE=Release \
    && rm -rf /opt/explore/build /opt/explore/log

COPY images/ros2/zenoh/session.json5.template /etc/zenoh/session.json5.template
COPY images/ros2/docker/entrypoint.sh /usr/local/bin/entrypoint
COPY explore/launch /opt/ovcs/launch
COPY explore/config /opt/ovcs/config
COPY explore/forward_explore/forward_explore_core.py explore/forward_explore/forward_explore_node.py /opt/ovcs/forward_explore/
RUN chmod 0755 /usr/local/bin/entrypoint

ENTRYPOINT ["/usr/local/bin/entrypoint"]
# Both explorers start driving as soon as they run, so the container
# only idles; exploration is launched on demand (see ../../README.md).
CMD ["sleep", "infinity"]
