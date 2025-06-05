# ROSBridgeFirmware

export ROS_INSTALL_FROM_SOURCE=true
export ROS_DIR=/home/loo/Development/ros2_ws/install
docker build --platform linux/arm64/v8 -t loicvigneron/ros-jazzy-zenoh:arm64v8 -f Dockerfile.arm64v8 .
export ZENOH_ROUTER_CONFIG_URI=/home/loo/Development/OVCS/ovcs/bridges/ros_bridge/firmware/rootfs_overlay/etc/DEFAULT_RMW_ZENOH_ROUTER_CONFIG.json5
export RMW_IMPLEMENTATION=rmw_zenoh_cpp



    1  ls
    2  cd zenoh-plugin-ros2dds/target/release/zenoh-bridge-ros2dds
    3  zenoh-plugin-ros2dds/target/release/zenoh-bridge-ros2dds
    4  ls
    5  cd ..
    6  ls
    7  cd /root/zenoh-plugin-ros2dds/
    8  ls
    9  ls zenoh-plugin-dds/target/release/zenoh-bridge-dds
   10  ls
   11  cp target/release/zenoh-bridge-ros2dds /mnt/
   12  apt-cache search zenoh
   13  apt-get install y ros-jazzy-rmw-zenoh-cpp
   14  apt-get install ros-jazzy-rmw-zenoh-cpp
   15  cd
   16  cp -R /opt/ros/jazzy/lib/rmw_zenoh_cpp /mnt/opt/ros/jazzy/lib/
   17  cd /lib
   18  ls
   19  cd aarch64-linux-gnu/
   20  ls
   21  cd /opt/ros/
   22  ls
   23  cd ..
   24  ls
   25  cd ros/jazzy/
   26  ls
   27  cd share/
   28  ls
   29  cd zenoh_cpp_vendor/
   30  ls
   31  cd cmake/
   32  ls
   33  cd ..
   34  ls
   35  cd ..
   36  ls
   37  cd lib/
   38  ls
   39  ls | grep zenoh
   40  ls rmw_zenoh_cpp/rmw_zenohd
   41  cd rmw_zenoh_cpp/
   42  ls
   43  ./rmw_zenohd
   44  find ~ -name libzenohc.so 2>/dev/null
   45  find / -name libzenohc.so 2>/dev/null
   46  cd ..
   47  ls
   48  cp -R /opt/ros/jazzy/opt/zenoh_cpp_vendor /mnt/opt/ros/jazzy/lib/
   49  ls | grep zenoh
   50  cp librmw_zenoh_cpp.so /mnt/opt/ros/jazzy/lib/
   51  ls /mnt/opt/ros/jazzy/ | grep zenoh
   52  ls /mnt/opt/ros/jazzy/lib | grep zenoh
   53  ls
   54  cd rmw_zenoh_cpp/
   55  ls
   56  cd ../
   57  ls
   58  cd ..
   59  ls
   60  cd lib/
   61  ls
   62  cd /mnt/
   63  ls
   64  cd lib/
   65  ls
   66  ../opt/ros/jazzy/
   67  ls
   68  cd ../opt/ros/jazzy/
   69  ls
   70  cd lib/
   71  ls
   72  cd zenoh_cpp_vendor/
   73  ls
   74  cd lib/
   75  ls
   76  cp libzenohc.so ../../
   77  cd ../../
   78  ls
   79  ls | grep zenoh
   80  rm -rf librmw_zenoh_cpp.so libzenohc.so rmw_zenoh_cpp zenoh_cpp_vendor
   81  apt-cache search cyclone
   82  apt-get install ros-jazzy-cyclonedds
   83  apt-get install ros-jazzy-rmw-cyclonedds-cpp
   84  ls
   85  ls | grep cyclone
   86  cd /opt/ros/jazzy/
   87  ls | grep cyclone
   88  ls
   89  cd lib/
   90  ls | grep cyclone
   91  cp librmw_cyclonedds_cpp.so /mnt/opt/ros/jazzy/lib/
   92  ls | grep libddsc
   93  ls | grep libd
   94  ls
   95  find / -name libdd 2>/dev/null
   96  find / -name libddsc.so 2>/dev/null
   97  cp /opt/ros/jazzy/lib/aarch64-linux-gnu/libddsc.so /mnt/opt/ros/jazzy/lib/
   98*
   99  find / -name libiceoryx_binding_c.so 2>/dev/null
  100  cp /opt/ros/jazzy/lib/aarch64-linux-gnu/libiceoryx_binding_c.so* /mnt/opt/ros/jazzy/lib/
  101  cp /opt/ros/jazzy/lib/aarch64-linux-gnu/libiceoryx* /mnt/opt/ros/jazzy/lib/
  102  find / -name libacl.so 2>/dev/null
  103  cp /usr/lib/aarch64-linux-gnu/libacl.so /mnt/opt/ros/jazzy/lib/
  104  cp /usr/lib/aarch64-linux-gnu/libacl.so* /mnt/opt/ros/jazzy/lib/
  105  history
