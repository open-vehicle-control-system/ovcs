# Base ROS 2 Jazzy image preloaded with rmw_zenoh + envsubst so the
# `ros2` compose service starts cold without an apt round-trip.
FROM ros:jazzy-ros-base

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ros-jazzy-rmw-zenoh-cpp \
        gettext-base \
        python3-pip \
    && rm -rf /var/lib/apt/lists/* \
    && pip3 install --no-cache-dir --break-system-packages \
        eclipse-zenoh==1.9.0
