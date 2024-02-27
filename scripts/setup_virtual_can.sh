#!/bin/bash
sudo modprobe vcan

sudo ip link set down vcan0
sudo ip link add dev vcan0 type vcan
sudo ip link set up vcan0

sudo ip link set down vcan1
sudo ip link add dev vcan1 type vcan
sudo ip link set up vcan1

sudo ip link set down vcan2
sudo ip link add dev vcan2 type vcan
sudo ip link set up vcan2

sudo ip link set down vcan3
sudo ip link add dev vcan3 type vcan
sudo ip link set up vcan3

echo "You can now listen to the virtual can inferface using: $ candump -tz vcanXX"
echo "You can send test frames with: $ cansend vcan0 123#00FFAA5501020304"
