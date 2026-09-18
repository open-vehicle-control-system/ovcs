# Nav2 for a vehicle's compute node: the servers, the shared entrypoint
# and a generic launch file, and nothing about any one vehicle. A
# vehicle bakes its parameters on top:
#
#   FROM ghcr.io/open-vehicle-control-system/ovcs/nav2:latest
#   COPY config /opt/ovcs/config
#
# (see vehicles/ovcs_mini/compute/nav2/Dockerfile), and the local
# stacks build that vehicle image so a workstation runs what the car
# runs. Published to GHCR by .github/workflows/ros2.yml.
#
# Standalone FROM the public base rather than FROM the ros2 image:
# Nav2 needs none of the Foxglove, camera and joystick packages that
# image carries. The entrypoint and Zenoh template are COPYed from
# ../ros2 instead — the build context is compose/images/ — so Zenoh
# and ROS init stay identical to every other service on the fabric.
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

COPY ros2/zenoh/session.json5.template /etc/zenoh/session.json5.template
COPY ros2/docker/entrypoint.sh /usr/local/bin/entrypoint
COPY nav2/launch /opt/ovcs/launch
RUN chmod 0755 /usr/local/bin/entrypoint

# The launch file reads /opt/ovcs/config/nav2.yaml. This image ships
# none: a vehicle's derived image COPYs its own, and the simulator
# bind-mounts one, so running this image bare fails at launch by
# design rather than planning with somebody else's wheelbase.
ENTRYPOINT ["/usr/local/bin/entrypoint"]
CMD ["bash", "-lc", "ros2 launch /opt/ovcs/launch/nav2.launch.py"]
