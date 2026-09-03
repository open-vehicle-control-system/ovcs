# Gazebo Jetty + ROS 2 Lyrical image for simulating the OVCS Mini.
#
# Separate from the vehicle image on purpose. This one carries Gazebo
# and its GUI stack — hundreds of megabytes that must never end up on
# the balena device, which has no display and no use for a physics
# engine. The vehicle image stays as small as the car needs.
#
# The build context is `ros2/`, not this directory, so the Zenoh
# session template and entrypoint are shared with the vehicle image
# rather than duplicated. One template, one renderer, one place to fix
# a fabric setting.
#
#   docker compose build          # from ros2/simulation/

FROM ros:lyrical-ros-base

# ros-lyrical-ros-gz pulls Gazebo in through the ROS vendor packages
# (ros-lyrical-gz-sim-vendor and friends) — there is no separate
# `gz-jetty` package and no OSRF apt repository to add.
#
# Lyrical pairs with Gazebo **Jetty** (LTS). That pairing is why the
# stack moved off Jazzy at all: Jazzy's only supported Gazebo is
# Harmonic, and Jetty against it is a flat "unsupported" rather than
# a cautious yes.
#
# The model this replaces targeted Gazebo *Classic*, two generations
# further back and end-of-life, whose
# `libgazebo_ros_ackermann_drive.so` exists in none of these.
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ros-lyrical-ros-gz \
        ros-lyrical-rmw-zenoh-cpp \
        ros-lyrical-xacro \
        ros-lyrical-robot-state-publisher \
        ros-lyrical-joint-state-publisher \
        ros-lyrical-teleop-twist-joy \
        ros-lyrical-joy-linux \
        ros-lyrical-tf2-ros \
        gettext-base \
    && rm -rf /var/lib/apt/lists/*

# Shared with the vehicle image — see the note on the build context.
COPY vehicule/image/zenoh/session.json5.template /etc/zenoh/session.json5.template
COPY vehicule/image/docker/entrypoint.sh         /usr/local/bin/entrypoint

# The simulator is baked; the vehicle models are not.
#
# A model describes one vehicle, so it lives with that vehicle —
# `vehicles/<name>/description/` — not here and not in the image. That
# is outside this build context on purpose, and the compose file
# mounts it to /opt/ovcs/vehicles/<name>. Running this image without
# those mounts gives you a simulator with nothing to spawn.
#
# (It sits beside `priv/` rather than inside it: `priv` is an Elixir
# application's private directory, and nothing in the Elixir tree
# reads a xacro.)
COPY simulation/common/   /opt/ovcs/common/
COPY simulation/launch/   /opt/ovcs/launch/
COPY simulation/worlds/   /opt/ovcs/worlds/
COPY simulation/config/   /opt/ovcs/config/
COPY simulation/scripts/  /opt/ovcs/scripts/

# `COPY --chmod=` needs BuildKit, which balenaEngine does not
# implement. This image never goes near balena, but the two images
# share an entrypoint and drifting between them costs more than the
# extra layer. Same reason as ../vehicule/image/Dockerfile.
RUN chmod 0755 /usr/local/bin/entrypoint

ENV OVCS_VEHICLES_DIR=/opt/ovcs/vehicles

# Gazebo needs somewhere writable for its own config and cache.
ENV HOME=/tmp

ENTRYPOINT ["/usr/local/bin/entrypoint"]
CMD ["bash", "-lc", "sleep infinity"]
