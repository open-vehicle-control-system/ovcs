#!/bin/bash

source /opt/ros/${ROS_DISTRO}/setup.bash

if [ -f ${WORKDIR}/install/setup.bash ]
then
  source ${WORKDIR}/install/setup.bash
fi

exec "$@"