# ROSBridgeFirmware

**TODO: Add description**

`sudo ln -s PATHT_TO/ros_bridge/firmware/rootfs_overlay/opt/ros/ /opt/ros`
`docker run --rm -ti --platform linux/arm64/v8 -v /home/loo/Development/OVCS/ovcs/bridges/ros_bridge/firmware/rootfs_overlay:/mnt ros:humble-ros-core bash`

`docker run --rm -ti --platform linux/amd64/v3 -v /opt:/mnt ros:humble-ros-core bash`
sudo cp /usr/lib/x86_64-linux-gnu/libspdlog.so /opt/ros/humble/lib/libspdlog.so.1
