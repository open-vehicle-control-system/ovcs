# Gazebo Jetty + ROS 2 Lyrical image for simulating a vehicle.
#
# Separate from the vehicle image on purpose: Gazebo and its graphical
# interface are hundreds of megabytes the vehicle, which has no display,
# never needs.
#
# The build context is `compose/`, not this directory, so the Zenoh
# session template and entrypoint are COPYed from the car's own image
# (compute/images/ros2) rather than duplicated. One template, one
# renderer, one place to fix a fabric setting.
#
#   docker compose -f simulation.yml build          # from compose/local/

FROM ros:lyrical-ros-base

# ros-lyrical-ros-gz brings Gazebo Jetty, Lyrical's pairing, through the
# ROS vendor packages: there is no separate Gazebo apt repository to add.
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ros-lyrical-ros-gz \
        ros-lyrical-rmw-zenoh-cpp \
        ros-lyrical-xacro \
        ros-lyrical-robot-state-publisher \
        gettext-base \
    && rm -rf /var/lib/apt/lists/*

# Shared with the vehicle image — see the note on the build context.
COPY compute/images/ros2/zenoh/session.json5.template /etc/zenoh/session.json5.template
COPY compute/images/ros2/docker/entrypoint.sh         /usr/local/bin/entrypoint

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
COPY local/simulation/common/   /opt/ovcs/common/
COPY local/simulation/launch/   /opt/ovcs/launch/
COPY local/simulation/worlds/   /opt/ovcs/worlds/

# `COPY --chmod=` needs BuildKit, which balenaEngine does not
# implement. This image never goes near balena, but the two images
# share an entrypoint and drifting between them costs more than the
# extra layer. Same reason as ../../../compute/images/ros2/Dockerfile.
RUN chmod 0755 /usr/local/bin/entrypoint

ENV OVCS_VEHICLES_DIR=/opt/ovcs/vehicles

# Gazebo needs somewhere writable for its own config and cache.
ENV HOME=/tmp

ENTRYPOINT ["/usr/local/bin/entrypoint"]
CMD ["bash", "-lc", "sleep infinity"]
