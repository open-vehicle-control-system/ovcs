#!/bin/bash
sudo modprobe vcan
sudo ip link set down vcan0
sudo ip link add dev vcan0 type vcan
sudo ip link set up vcan0
echo "You can now listen to the virtual can inferface using: $ candump -tz vcan0"
echo "You can send test frames with: $ cansend vcan0 123#00FFAA5501020304"
