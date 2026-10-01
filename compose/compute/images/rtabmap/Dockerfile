# RTAB-Map for the vehicle's compute node: builds the map from the
# rectified left image, the depth image and /odom, and publishes /map
# and map -> odom. Built like ../nav2/Dockerfile, from the same pinned
# base and ROS snapshot, with the shared entrypoint and Zenoh template.
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
        ros-lyrical-rtabmap-slam \
        ros-lyrical-compressed-image-transport \
        gettext-base \
    && rm -rf /var/lib/apt/lists/*

COPY images/ros2/zenoh/session.json5.template /etc/zenoh/session.json5.template
COPY images/ros2/docker/entrypoint.sh /usr/local/bin/entrypoint
COPY rtabmap/launch /opt/ovcs/launch
COPY rtabmap/config /opt/ovcs/config
RUN chmod 0755 /usr/local/bin/entrypoint

ENTRYPOINT ["/usr/local/bin/entrypoint"]
CMD ["bash", "-lc", "ros2 launch /opt/ovcs/launch/rtabmap.launch.py"]
