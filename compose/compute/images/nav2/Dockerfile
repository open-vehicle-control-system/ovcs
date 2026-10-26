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
# The launch file is the framework's; the parameters and the URDF are
# the vehicle's (vehicles/<vehicle>/nav2/ and description/<vehicle>.urdf),
# staged into vehicle/ by `ovcs compute stage` and baked in, since
# balenaOS has no host bind mounts. Built from the repo,
# compose/compute/vehicle/ is empty: the image fails at launch until the
# local stacks mount a vehicle's files.
# Pinned: the base by digest (its ROS packages are the 2026-08-12 sync)
# and apt to the ROS snapshot of 2026-08-19, so every build installs the
# same packages. Bump both together; the snapshot key expires 2027-06-01.
FROM ros:lyrical-ros-base@sha256:0c19f326a339ed770ef1d4c0646a8b53bdb49dd5ff74b6de41ebdb8ac21e1806 AS ros-snapshot

COPY images/ros2/ros-snapshots.asc /usr/share/keyrings/ros-snapshots.asc
RUN printf '%s\n' \
        'Types: deb' \
        'URIs: http://snapshots.ros.org/lyrical/2026-08-19/ubuntu' \
        'Suites: resolute' \
        'Components: main' \
        'Signed-By: /usr/share/keyrings/ros-snapshots.asc' \
        > /etc/apt/sources.list.d/ros2.sources

# The Smac planners are released for Lyrical but absent from its
# archive, so they are built from that release's source, at the version
# of the Nav2 packages installed below, and staged into the ROS tree as
# the Debian package would install them.
FROM ros-snapshot AS smac-planner

ARG SMAC_RELEASE=dde95b3098a822d07b5a25434bd779a5570ab950
ARG SMAC_SHA256=f8bc3a09f43a55291d181f4922395b4d823d732a99014fa6e0149b5bcc8b7f14
RUN apt-get update \
    && apt-get upgrade -y --no-install-recommends \
    && apt-get install -y --no-install-recommends \
        build-essential \
        cmake \
        curl \
        ca-certificates \
        libboost-filesystem-dev \
        libboost-program-options-dev \
        libboost-serialization-dev \
        libboost-system-dev \
        libeigen3-dev \
        nlohmann-json3-dev \
        ros-lyrical-angles \
        ros-lyrical-backward-ros \
        ros-lyrical-nav2-common \
        ros-lyrical-nav2-core \
        ros-lyrical-nav2-costmap-2d \
        ros-lyrical-nav2-ros-common \
        ros-lyrical-nav2-util \
        ros-lyrical-ompl \
        ros-lyrical-visualization-msgs \
    && rm -rf /var/lib/apt/lists/*
RUN curl -fsSL -o /tmp/smac.tar.gz \
        "https://github.com/ros2-gbp/navigation2-release/archive/${SMAC_RELEASE}.tar.gz" \
    && echo "${SMAC_SHA256}  /tmp/smac.tar.gz" | sha256sum -c - \
    && mkdir /tmp/smac \
    && tar -xzf /tmp/smac.tar.gz --strip-components=1 -C /tmp/smac \
    && . /opt/ros/lyrical/setup.sh \
    && cmake -S /tmp/smac -B /tmp/smac/build \
        -DCMAKE_BUILD_TYPE=Release \
        -DBUILD_TESTING=OFF \
        -DCMAKE_INSTALL_PREFIX=/opt/ros/lyrical \
    && cmake --build /tmp/smac/build -j"$(nproc)" \
    && DESTDIR=/staging cmake --install /tmp/smac/build

FROM ros-snapshot

# Individual servers rather than a metapackage: there is no
# `ros-lyrical-navigation2` or `ros-lyrical-nav2-bringup` in the
# Lyrical archive, and naming what we run keeps the image honest
# about it. ompl and backward_ros are the Smac planners' runtime
# dependencies. octomap_server, topic_tools and point_cloud_transport are not
# Nav2's: they map and compress the stereo cloud for the displays, see the
# launch file.
# Upgrade first, so the base's packages match the snapshot's: packages
# built against a newer rosidl fail at load with undefined symbols.
RUN apt-get update \
    && apt-get upgrade -y --no-install-recommends \
    && apt-get install -y --no-install-recommends \
        ros-lyrical-rmw-zenoh-cpp \
        ros-lyrical-nav2-controller \
        ros-lyrical-nav2-mppi-controller \
        ros-lyrical-nav2-planner \
        ros-lyrical-ompl \
        ros-lyrical-backward-ros \
        ros-lyrical-nav2-bt-navigator \
        ros-lyrical-nav2-behaviors \
        ros-lyrical-nav2-velocity-smoother \
        ros-lyrical-nav2-behavior-tree \
        ros-lyrical-nav2-lifecycle-manager \
        ros-lyrical-nav2-costmap-2d \
        ros-lyrical-spatio-temporal-voxel-layer \
        ros-lyrical-nav2-simple-commander \
        ros-lyrical-nav2-msgs \
        ros-lyrical-robot-state-publisher \
        ros-lyrical-octomap-server \
        ros-lyrical-topic-tools \
        ros-lyrical-point-cloud-transport \
        ros-lyrical-draco-point-cloud-transport \
        gettext-base \
    && rm -rf /var/lib/apt/lists/*

COPY --from=smac-planner /staging/opt/ros/lyrical /opt/ros/lyrical
COPY images/ros2/zenoh/session.json5.template /etc/zenoh/session.json5.template
COPY images/ros2/docker/entrypoint.sh /usr/local/bin/entrypoint
COPY images/nav2/launch /opt/ovcs/launch
COPY vehicle/nav2 /opt/ovcs/config
COPY vehicle/description /opt/ovcs/description
RUN chmod 0755 /usr/local/bin/entrypoint

ENTRYPOINT ["/usr/local/bin/entrypoint"]
CMD ["bash", "-lc", "ros2 launch /opt/ovcs/launch/nav2.launch.py"]
