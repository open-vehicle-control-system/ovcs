# Foxglove WebSocket bridge over ROS 2 Jazzy, on rmw_zenoh.
FROM ros:jazzy-ros-base

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ros-jazzy-foxglove-bridge \
        ros-jazzy-rmw-zenoh-cpp \
        gettext-base \
    && rm -rf /var/lib/apt/lists/*
