# Single ROS 2 Jazzy image powering every service in this compose
# stack (`ros2`, `foxglove_bridge`, `joy`). Each service picks its
# launcher via the image's CMD or a compose-level override; the
# ENTRYPOINT (cross-cutting Zenoh + ROS init) is the same for all of
# them, so there's no point in maintaining separate images.
FROM ros:jazzy-ros-base

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ros-jazzy-rmw-zenoh-cpp \
        ros-jazzy-foxglove-bridge \
        ros-jazzy-joy-linux \
        ros-jazzy-vision-msgs \
        ros-jazzy-image-transport-plugins \
        ros-jazzy-stereo-image-proc \
        ros-jazzy-camera-calibration \
        ros-jazzy-cv-bridge \
        python3-opencv \
        gettext-base \
        python3-pip \
    && rm -rf /var/lib/apt/lists/* \
    && pip3 install --no-cache-dir --break-system-packages \
        eclipse-zenoh==1.9.0

COPY --chmod=0755 docker/entrypoint.sh         /usr/local/bin/entrypoint
COPY --chmod=0755 docker/foxglove_bridge.sh    /usr/local/bin/foxglove_bridge
COPY --chmod=0755 docker/joy.sh                /usr/local/bin/joy
COPY --chmod=0755 docker/calibrator.sh         /usr/local/bin/calibrator
COPY --chmod=0755 docker/decompress_stereo.py  /usr/local/bin/decompress_stereo

ENTRYPOINT ["/usr/local/bin/entrypoint"]
# Default CMD idles so `docker compose up ros2` keeps the container
# alive for `docker compose exec ros2 …`. Per-service compose entries
# override this with the matching launcher (foxglove_bridge / joy).
CMD ["tail", "-f", "/dev/null"]
