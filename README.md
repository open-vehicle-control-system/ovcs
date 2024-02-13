# OVCS

## What is OVCS?

OVCS stands for Open Vehicule Control system. It is a set of open-hardware and open-software components meant as a development platform for tinkering with vehicules.

OVCS is based on simple, off-the-shelve components to make it affordable and accessible to people with no to limited knowledge about the embedded computing world.

OVCS can help you:
* Retrofit a car or any other vehicule by providing an easy to modify system to interact with the vehicule's CAN buses
* Create a dashboard for any kind of vehicule using high-level web technologies such as the  Phoenix framework and Vue.js
* Make multiple components from different vehicule brands work together by aggregating the different CAN buses and providing a standardized set of CAN messages on the OVCS CAN bus.

## Disclaimer

OVCS is provided as is an without any warranty. Use it at your own risk. It is not road certified and therefore does not meet all required criteria to do so. We decline any responsibility for any incident resulting in the usage of OVCS. OVCS is a hobby research project.

## Table of content

1. [Getting started](./getting_started.md)
2. [Applications](./applications.md)
3. [Testing Can messages](./testing_can_messages.md)
4. [Hardware architecture](./hardware_architecture.md)
5. [Running on hardware](./running_hardware.md)

## Test can frames

### Handbrake 

* engaged: `cansend vcan0 320#03027F0100000000`
* disengaged `cansend vcan0 320#03007F0100000000`

## RPM

* 1250 rpm: `cansend vcan0 280#0000881300000000`
* 2250 rpm: `cansend vcan0 280#0000282300000000`

## Deploy

* Run `./build.sh` to build the firmware then, either:
    * run `./burn.sh` to burn a sd card
    * run `./upload_over_usb.sh` to update an existing Raspberry connected to your host over USB 

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

## Start Sequence

- Key contact on 
- 12V enabled everywhere
- Key start engine
- Switch on signal -> Arduino controller (grouped with controls or not?) enable 12V to Inverter, water pump, vacuum pump
- Within 2 seconds, ECU sends VMS frames (Status, alive, torque)
- ECU request main negative contactor ON
- Contactors controller: Main negative contactor ON
- ECU request precharge contactor ON
- Contactors controller: Main precharge contactor ON
- ECU check precharge complete (Based on BMS?)
- ECU request main positive contactor ON
- Contactors controller: Main positive contactor ON
- ECU request precharge contactor OFF
- Contactors controller: precharge contactor OFF


## OVCS CAN MESSAGES

### Car Controls calibration mode

- ID: 0x500
- Data:
    - Byte 0 (Mode): 0 == OFF / 1 == ON
- Frequency: 200ms

### Car Controls status

- ID: 0x200 
- Data:
    - Byte 0 (Throttle): 0 - 255 -> 0 to 100% 
- Frequency: 10ms

## Contactors state request (sent by ECU)

- ID: 0x100
- Data: 
    - Byte 0 (Main negative Contactor): 0 == OFF / 1 == ON
    - Byte 1 (Main positive Contactor): 0 == OFF / 1 == ON
    - Byte 2 (Precharge contactor):  0 == OFF / 1 == ON
Frequency: 20ms

## Contactors status (sent by contactors controller)

- ID: 0x101
- Data: 
    - Byte 0 (Main negative Contactor): 0 == OFF / 1 == ON
    - Byte 1 (Main positive Contactor): 0 == OFF / 1 == ON
    - Byte 2 (Precharge contactor):  0 == OFF / 1 == ON
Frequency: 10ms
