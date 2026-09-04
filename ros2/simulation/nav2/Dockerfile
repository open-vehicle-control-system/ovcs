# Nav2 for the simulated OVCS Mini.
#
# Derived from the shared base-station image rather than adding these
# packages to it. Nav2 is several hundred megabytes, `ros2/vehicule/image`
# is what balena ships to the RPis, and the car cannot use Nav2 until the
# real-vehicle track lands (staleness failsafe, arbitration, odometry).
# Promoting Nav2 into the shared image is a deliberate call to make then,
# not a side effect of wanting it in the simulator now.
#
# It inherits the base image's ENTRYPOINT, so Zenoh and ROS init are the
# same here as everywhere else on the fabric.
FROM ovcs/ros2:lyrical

# Individual servers rather than a metapackage: there is no
# `ros-lyrical-navigation2` or `ros-lyrical-nav2-bringup` in the Lyrical
# archive, and naming what we run keeps the image honest about it.
#
# nav2-behaviors is included even though the behaviour tree here does not
# use Spin — bt_navigator's default plugin list loads the behavior server's
# action clients at configure time.
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ros-lyrical-nav2-controller \
        ros-lyrical-nav2-mppi-controller \
        ros-lyrical-nav2-planner \
        ros-lyrical-nav2-navfn-planner \
        ros-lyrical-nav2-bt-navigator \
        ros-lyrical-nav2-behaviors \
        ros-lyrical-nav2-behavior-tree \
        ros-lyrical-nav2-lifecycle-manager \
        ros-lyrical-nav2-costmap-2d \
        ros-lyrical-nav2-simple-commander \
        ros-lyrical-nav2-msgs \
    && rm -rf /var/lib/apt/lists/*
