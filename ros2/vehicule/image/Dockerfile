# Single ROS 2 Jazzy image powering every service on both sides of the
# fabric: `foxglove_bridge` on the vehicle (../docker-compose.yml) and
# `ros2` / `joy` / `calibrator` on the base station
# (../../base/docker-compose.yml). Each service picks its launcher via
# the image's CMD or a compose-level override; the ENTRYPOINT
# (cross-cutting Zenoh + ROS init) is the same for all of them, so
# there's no point in maintaining separate images.
#
# Lives under ros2/vehicule/image/ because balena requires every build
# context to sit inside the pushed source root — the base station
# reaches across to it (`context: ../vehicule/image`), which plain
# `docker compose` is happy to do.
FROM ros:lyrical-ros-base

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ros-lyrical-rmw-zenoh-cpp \
        ros-lyrical-foxglove-bridge \
        ros-lyrical-foxglove-msgs \
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
        eclipse-zenoh==1.9.0

# Baked in rather than bind-mounted: balenaOS has no host bind mounts,
# and keeping one mechanism means the vehicle and the base station read
# the identical template. Editing it means a rebuild.
COPY zenoh/session.json5.template /etc/zenoh/session.json5.template

# `COPY --chmod=` would be tidier, but it is a BuildKit-only feature and
# balenaEngine does not implement BuildKit — the build fails outright on
# the device and on balena's builders. Copy, then chmod in one layer,
# which every builder understands. The chmod is not belt-and-braces:
# docker/calibrator.sh is mode 644 in git.
COPY docker/entrypoint.sh         /usr/local/bin/entrypoint
COPY docker/foxglove_bridge.sh    /usr/local/bin/foxglove_bridge
COPY docker/joy.sh                /usr/local/bin/joy
COPY docker/calibrator.sh         /usr/local/bin/calibrator
COPY docker/decompress_stereo.py  /usr/local/bin/decompress_stereo
RUN chmod 0755 \
        /usr/local/bin/entrypoint \
        /usr/local/bin/foxglove_bridge \
        /usr/local/bin/joy \
        /usr/local/bin/calibrator \
        /usr/local/bin/decompress_stereo

ENTRYPOINT ["/usr/local/bin/entrypoint"]
# Default CMD idles so `docker compose up ros2` keeps the container
# alive for `docker compose exec ros2 …` on the base station.
# Per-service compose entries override this with the matching launcher
# (foxglove_bridge / joy / calibrator).
CMD ["tail", "-f", "/dev/null"]
