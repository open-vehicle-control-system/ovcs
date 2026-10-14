# Single ROS 2 Lyrical image powering every service on both sides of the
# fabric: `foxglove_bridge` on the vehicle (../../docker-compose.yml)
# and `ros2` / `joy` / `calibrator` on the operator's machine
# (../../../local/base.yml). Each service picks its launcher via the
# image's CMD or a compose-level override; the ENTRYPOINT
# (cross-cutting Zenoh + ROS init) is the same for all of them, so
# there's no point in maintaining separate images.
#
# Lives under compose/compute/ because balena requires every build
# context to sit inside the pushed source root; the local stacks reach
# across to it (`context: ../compute`), which plain `docker compose` is
# happy to do. The direction matters: a workstation runs the image the
# car runs, never a copy of it. The context is that source root, like
# Nav2's, for the vehicle's description `ovcs compute stage` puts in
# vehicle/: foxglove_bridge serves its meshes. Built from the repo,
# vehicle/description is empty.
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

# Upgrade first, so the base's packages match the snapshot's: packages
# built against a newer rosidl fail at load with undefined symbols.
RUN apt-get update \
    && apt-get upgrade -y --no-install-recommends \
    && apt-get install -y --no-install-recommends \
        ros-lyrical-rmw-zenoh-cpp \
        ros-lyrical-foxglove-bridge \
        ros-lyrical-foxglove-msgs \
        # foxglove_bridge can only expose a topic or service whose
        # definition it can load: Nav2's costmaps, behaviour-tree log
        # and lifecycle services (nav2_msgs), costmap updates
        # (map_msgs) and the /bond heartbeat need these three.
        ros-lyrical-nav2-msgs \
        ros-lyrical-map-msgs \
        ros-lyrical-bond \
        # The stereo voxel layer's save_grid service: its type ships only
        # inside the plugin.
        ros-lyrical-spatio-temporal-voxel-layer \
        ros-lyrical-joy-linux \
        ros-lyrical-vision-msgs \
        ros-lyrical-image-transport-plugins \
        ros-lyrical-stereo-image-proc \
        ros-lyrical-camera-calibration \
        ros-lyrical-cv-bridge \
        python3-opencv \
        gettext-base \
        python3-pip \
    && rm -rf /var/lib/apt/lists/* \
    && pip3 install --no-cache-dir --break-system-packages \
        eclipse-zenoh==1.8.0 \
        websockets==17.0.1

# camera_calibration 7.1.7 predates Lyrical's rclpy and NumPy 2: the
# logger's warn() crashes cameracalibrator at start, ndarray.tostring()
# crashes SAVE.
RUN cd /opt/ros/lyrical/lib/python3.14/site-packages/camera_calibration \
    && sed -i 's/get_logger()\.warn(/get_logger().warning(/' camera_calibrator.py \
    && sed -i 's/\.tostring()/.tobytes()/' mono_calibrator.py stereo_calibrator.py

# Baked in rather than bind-mounted: balenaOS has no host bind mounts,
# and keeping one mechanism means the vehicle and the base station read
# the identical template. Editing it means a rebuild.
COPY images/ros2/zenoh/session.json5.template /etc/zenoh/session.json5.template

# `COPY --chmod=` would be tidier, but it is a BuildKit-only feature and
# balenaEngine does not implement BuildKit — the build fails outright on
# the device and on balena's builders. Copy, then chmod in one layer,
# which every builder understands. The chmod is not belt-and-braces:
# docker/calibrator.sh is mode 644 in git.
COPY images/ros2/docker/entrypoint.sh         /usr/local/bin/entrypoint
COPY images/ros2/docker/foxglove_bridge.sh    /usr/local/bin/foxglove_bridge
COPY images/ros2/docker/foxglove_compression.py /usr/local/bin/foxglove_compression
COPY images/ros2/docker/foxglove_watchdog.py  /usr/local/bin/foxglove_watchdog
COPY images/ros2/docker/joy.sh                /usr/local/bin/joy
COPY images/ros2/docker/joy_centring.py       /usr/local/bin/joy_centring
COPY images/ros2/docker/calibrator.sh         /usr/local/bin/calibrator
COPY images/ros2/docker/decompress_stereo.py  /usr/local/bin/decompress_stereo
RUN chmod 0755 \
        /usr/local/bin/entrypoint \
        /usr/local/bin/foxglove_bridge \
        /usr/local/bin/joy \
        /usr/local/bin/joy_centring \
        /usr/local/bin/calibrator \
        /usr/local/bin/decompress_stereo

COPY vehicle/description /opt/ovcs/description
# The description as the `ovcs_description` package, which the
# `package://` mesh URIs name; foxglove_bridge.sh puts the prefix on
# AMENT_PREFIX_PATH.
RUN mkdir -p /opt/ovcs/ament/share/ament_index/resource_index/packages \
    && touch /opt/ovcs/ament/share/ament_index/resource_index/packages/ovcs_description \
    && ln -s /opt/ovcs/description /opt/ovcs/ament/share/ovcs_description

ENTRYPOINT ["/usr/local/bin/entrypoint"]
# Default CMD idles so `docker compose up ros2` keeps the container
# alive for `docker compose exec ros2 …` on the base station.
# Per-service compose entries override this with the matching launcher
# (foxglove_bridge / joy / calibrator).
CMD ["tail", "-f", "/dev/null"]
