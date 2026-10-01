# Nav2 for the vehicle's compute node — and, built by the local stacks
# (../../../local/base.yml, ../../../local/simulation.yml) from the same
# context, for a workstation running the loop with no vehicle at all.
# One image, tagged ovcs/nav2:lyrical everywhere.
#
# Standalone FROM the public base rather than FROM ovcs/ros2:lyrical:
# balena's builders build each service from scratch and have no local
# ovcs/* tags to inherit from. The entrypoint and Zenoh template are
# COPYed from ../ros2 instead (the build context is compose/compute/,
# see ../../docker-compose.yml), so Zenoh and ROS init stay identical
# to every other service on the fabric.
#
# Launch file and parameters are baked in, not mounted: balenaOS has
# no host bind mounts. They are the same files the simulator mounts —
# compose/compute/nav2/{launch,config}/ is the single copy.
# Pinned: the base by digest (its ROS packages are the 2026-08-12 sync)
# and apt to the ROS snapshot of 2026-08-19, so every build installs the
# same packages. Bump both together; the snapshot key expires 2027-06-01.
FROM ros:lyrical-ros-base@sha256:0c19f326a339ed770ef1d4c0646a8b53bdb49dd5ff74b6de41ebdb8ac21e1806

COPY images/ros2/ros-snapshots.asc /usr/share/keyrings/ros-snapshots.asc
RUN printf '%s\n' \
        'Types: deb' \
        'URIs: http://snapshots.ros.org/lyrical/2026-08-19/ubuntu' \
        'Suites: resolute' \
        'Components: main' \
        'Signed-By: /usr/share/keyrings/ros-snapshots.asc' \
        > /etc/apt/sources.list.d/ros2.sources

# Individual servers rather than a metapackage: there is no
# `ros-lyrical-navigation2` or `ros-lyrical-nav2-bringup` in the
# Lyrical archive, and naming what we run keeps the image honest
# about it.
# Upgrade first, so the base's packages match the snapshot's: packages
# built against a newer rosidl fail at load with undefined symbols.
RUN apt-get update \
    && apt-get upgrade -y --no-install-recommends \
    && apt-get install -y --no-install-recommends \
        ros-lyrical-rmw-zenoh-cpp \
        ros-lyrical-nav2-controller \
        ros-lyrical-nav2-mppi-controller \
        ros-lyrical-nav2-regulated-pure-pursuit-controller \
        ros-lyrical-nav2-planner \
        ros-lyrical-nav2-navfn-planner \
        ros-lyrical-nav2-bt-navigator \
        ros-lyrical-nav2-behaviors \
        ros-lyrical-nav2-velocity-smoother \
        ros-lyrical-nav2-behavior-tree \
        ros-lyrical-nav2-lifecycle-manager \
        ros-lyrical-nav2-costmap-2d \
        ros-lyrical-spatio-temporal-voxel-layer \
        ros-lyrical-nav2-simple-commander \
        ros-lyrical-nav2-msgs \
        gettext-base \
    && rm -rf /var/lib/apt/lists/*

COPY images/ros2/zenoh/session.json5.template /etc/zenoh/session.json5.template
COPY images/ros2/docker/entrypoint.sh /usr/local/bin/entrypoint
COPY nav2/launch /opt/ovcs/launch
COPY nav2/config /opt/ovcs/config
RUN chmod 0755 /usr/local/bin/entrypoint

ENTRYPOINT ["/usr/local/bin/entrypoint"]
CMD ["bash", "-lc", "ros2 launch /opt/ovcs/launch/nav2.launch.py"]
