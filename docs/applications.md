# OVCS applications

## Introduction

OVCS is composed of several applications that can be ran on a host machine without the target hardware present.

These applications are the backend and frontend parts of the infotainment system and the VMS module.

Here is a description of the relevant directories containing the OVCS applications:

```
- infotainment: Infotainment system application written in Elixir with a in car UI written with Phoenix and Vue.js.
- vms: Vehicle Managment System, written in pure Elixir, with a debug UI writtent with Pheonix and Vue.js.
```

## Dependencies

Since OVCS relies on the CAN bus, you will need to make sure you have `libsocketcan` in your kernel and `can-utils`installed on your host machine. That way, you can create virtual can devices on your host which will allow you to run the software locally.

We provide a script to setup your local machine called `build_arduino_can.sh`:

```
#!/bin/sh
#sudo apt-get install can-utils
#sudo modprobe can
#sudo modprobe can_raw
sudo ip link set down can0
sudo ip link set down can1
sudo ip link set can0 type can bitrate 1000000
sudo ip link set can1 type can bitrate 1000000
sudo ip link set up can0
sudo ip link set up can1
```

You can run this script with the following command in your ovcs parent folder: `./build_arduino_can.sh`.

If your system is not setup to support can yet, you should uncomment the 3 first lines of this script so all necessary packages and modules get loaded properly.

```
sudo apt-get install can-utils
sudo modprobe can
sudo modprobe can_raw
```

## Local Development

* Run `mix phx.server` in the  `infotainment/api` folder to run the Phoenix app.
    * The CAN/BUS networks to be used can be configured with `export CAN_NETWORKS=drive:vcan0,confort:vcan1`
    * If the "ip link" command requires "sudo", you should configure the CAN networks manully and set the `SETUP_CAN_INTERFACE` environnment variable to `true`
    * The vehicle configuration to use ba be configured with `VEHICLE=polo-2007-bluemotion`

* Run `npm run dev` in the `infotainment/dashboard` folder to run the Vue.js app.

## Elixir x libsocketcan binding ([Source](https://elixirforum.com/t/erlang-socket-module-for-socketcan-on-nerves-device/57294))

You have to open an [erlang socket](https://www.erlang.org/doc/man/socket) with the following args:

* Domain: 29 == [AF_CAN](https://github.com/linux-can/linux/blob/56cfd2507d3e720f4b1dbf9513e00680516a0826/include/linux/socket.h#L193)
* Type: :raw
* Protocol: 1 ==  [CAN_RAW](https://github.com/linux-can/linux/blob/56cfd2507d3e720f4b1dbf9513e00680516a0826/include/uapi/linux/can.h#L154)

```elixir
{:ok, sock} = :socket.open(29, :raw, 1)
{:ok, ifindex} = :socket.ioctl(sock, :gifindex, 'can0') # Single quotes matters, you need a charlist not a binary
addr = <<0::size(16)-little, ifindex::size(32)-little, 0::size(32), 0::size(32), 0::size(64)>>
:socket.bind(sock, %{:family => 29, :addr => addr})
```

Next: [Testing with can messages](./testing_can_messages.md)