# OVCS infotainment 

## Applications

* `ovcs_infotainment_backend`: Phoenix app connecting to the CAN/Bus and exposing the internal API
* `ovcs_infotainment_firmware`: Nerves app packaging the backend on a Raspberry
* `ovcs_infotainment_frontend`: Vue.js App displaying the car interface. Served as static files by the backend app in prod

## Local Development

* Run `mix phx.server` in the  `ovcs_infotainment_backend` folder to run the Phoenix app.
    * The CAN/BUS networks to be used can be configured with `export CAN_NETWORKS=drive:vcan0,confort:vcan1`
    * If the "ip link" command requires "sudo", you should configure the CAN networks manully and set the `MANUAL_SETUP` environnment variable to `true`
    * The vehicle configuration to use ba be configured with `export VEHICLE=polo-2007-bluemotion`

* Run `npm run dev` in the `ovcs_infotainment_frontend` folder to run the Vue.js app.

## Test can frames

### Handbrake 

* engaged: `cansend vcan0 320#03027F0100000000`
* disengaged `cansend vcan0 320#03007F0100000000`

## RPM

* 1250 rpm: `cansend vcan0 280#0000881300000000`
* 2250 rpm: `cansend vcan0 280#0000282300000000`

## Speed

Need two frame to display

* 1A0#0000000000000000
* 5A0#0000600000000000

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

## Receive a message

Send the message using the following command:

```
cansend vcan0 111#FF11FF11FF11FF11
```

Receive with Elixir:

```elixir
{:ok, frame} = :socket.recv(sock) # Blocking until a message is received, Example: {:ok, <<17, 1, 0, 0, 8, 0, 0, 0, 255, 17, 255, 17, 255, 17, 255, 17>>}
<<frame_id::binary-size(2), _unused1::binary-size(2), frame_data_length::binary-size(1), _unused2::binary-size(3), frame_data::binary  >>} = frame
encoded_frame_id = Base.encode16(frame_id) # Example: "1101"
encoded_frame_data_length = :binary.decode_unsigned(frame_data_length) # Example: 8
encoded_frame_data = Base.encode16(frame_data) # Example: "FF11FF11FF11FF11"
```

## Send a message

Build a binary based on the structure defined above:

```elixir
:socket.send(sock, <<17, 1, 0, 0, 8, 0, 0, 0, 255, 17, 255, 17, 255, 17, 255, 17>>)
```

Receive it using the following command: 

```bash
$ candump -tz vcan0
(000.000000)  vcan0  111   [8]  FF 11 FF 11 FF 11 FF 11
```