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
FROM ros:lyrical-ros-base

# Individual servers rather than a metapackage: there is no
# `ros-lyrical-navigation2` or `ros-lyrical-nav2-bringup` in the
# Lyrical archive, and naming what we run keeps the image honest
# about it.
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ros-lyrical-rmw-zenoh-cpp \
        ros-lyrical-nav2-controller \
        ros-lyrical-nav2-mppi-controller \
        ros-lyrical-nav2-planner \
        ros-lyrical-nav2-navfn-planner \
        ros-lyrical-nav2-bt-navigator \
        ros-lyrical-nav2-behaviors \
        ros-lyrical-nav2-behavior-tree \
        ros-lyrical-nav2-lifecycle-manager \
        ros-lyrical-nav2-costmap-2d \
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
