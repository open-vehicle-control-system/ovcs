# OVCS infotainment 

## Local environment setup

* Install asdf: `git clone https://github.com/asdf-vm/asdf.git ~/.asdf`
* Install erlang:  `asdf plugin add erlang https://github.com/asdf-vm/asdf-erlang.git && asdf install erlang 26.1.2 && asdf global erlang 26.1.2`
* Install elixir: `asdf plugin-add elixir https://github.com/asdf-vm/asdf-elixir.git && asdf install elixir 1.15.7 && asdf global elixir 1.15.7`
* Install NVM: `curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.5/install.sh | bash`
* Install Node: `nvm install node`
* Install NPM: `npm install -g npm`
* Install nervers: See https://hexdocs.pm/nerves/installation.html
* Install can-utils: `sudo apt-get install can-utils`

## Applications

* `ovcs_infotainment_backend`: Phoenix app connecting to the CAN/Bus and exposing the internal API
* `ovcs_infotainment_firmware`: Nerves app packaging the backend on a Raspberry
* `ovcs_infotainment_frontend`: Vue.js App displaying the car interface. Served as static files by the backend app in prod

## Local Development

* Run `mix phx.server` in the  `ovcs_infotainment_backend` folder to run the Phoenix app.
    * The CAN/BUS networks to be used can be configured with `export CAN_NETWORKS=drive:vcan0,confort:vcan1`
    * If the "ip link" command requires "sudo", you should configure the CAN networks manully and set the `MANUAL_SETUP` environnment variable to `true`
    * The vehicle configuration to use ba be configured with `VEHICLE=polo-2007-bluemotion`

* Run `npm run dev` in the `ovcs_infotainment_frontend` folder to run the Vue.js app.
* You can simulate the vehicle (infinite loop) with the following command: `canplayer -l i -I candumps/candump-standard-test.log vcan0=can0 vcan1=can1`

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
