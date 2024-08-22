# Running OVCS on real hardware

Currently supported hardware:

| Component    | Hardware platform | Supported |
|--------------|-------------------|----------------|
| Infotainment | Raspberry Pi 4    |:white_check_mark:|
| VMS          | Raspberry Pi 4    |:white_check_mark:|
| Controller   | Arduino R4 Minima |:white_check_mark:|

## Firmware code

OVCS uses the [Nerves Project](https://github.com/nerves-project) to build the firmware of the VMS and Infotainment systems. In theory, any system supported by Nerves should be able to run our OVCS firmware code.

For the Controller, we use basic Arduino C++, which means you will need to upload it to your arduinos using the [Arduino IDE](https://www.arduino.cc/en/software) or [Platform.io](https://platformio.org/).

Our controllers don't use the internal CAN bus of the Arduino R4 Minima, to remain relatively independent. In some cases, reading and writing on the EEPROM is necessary, so in theory, any Arduino compatible board with EEPROM read/write capabilities should be able to run our controllers firmware code.

## Configuring firmware targets

By default, the Infotainment and VMS targets are set to our custom raspberry pi 4 systems. You can see an example of this by looking into the `mix.exs` file in `ovcs_infotainment_firmware`:

```elixir
# ovcs_infotainment_firmware/mix.exs
defmodule OvcsInfotainmentFirmware.MixProject do
  use Mix.Project

  @app :ovcs_infotainment_firmware
  @version "0.1.0"
  @all_targets [
    :rpi4, :ovcs_infotainment_system_rpi4
  ]

  # ...
  defp deps do
    # Dependencies for specific targets
    # NOTE: It's generally low risk and recommended to follow minor version
    # bumps to Nerves systems. Since these include Linux kernel and Erlang
    # version updates, please review their release notes in case
    # changes to your application are needed.
    {
    :ovcs_infotainment_system_rpi4,
    path: "../../ovcs_infotainment_system_rpi4",
    runtime: false,
    targets: :ovcs_infotainment_system_rpi4,
    nerves: [compile: true]
    },
  ]
end
```

If you are trying to run the infotainment on an unsupported system, you will need to change the references to `ovcs_infotainment_system_rpi4` so that it references your own custom system.

For more documentation on linking our firmware to a different system, please consult the [Nerves Project documentation on custom systems](https://hexdocs.pm/nerves/customizing-systems.html).

## Deploying the firmware

OVCS provides some basic scripts to make your life easier.

| Script                            | Purpose             |
|-----------------------------------|---------------------|
| ./ovcs-cli build vms/infotainment | Builds the firmware for the VMS/Infotainment     |
| ./ovcs-cli upload vms/infotainment |  Uploads the latest VMS/Infotainment built firmware to the USB connected device |

## Customizing CAN interfaces.

You can customize the CAN, VCAN or SPI interface to be used for each CAN network using the `CAN_NETWORK_MAPPINGS` environment variable (locally or when building the the target firmware).

### Running the VMS locally with custom CAN and VCAN interfaces:

```sh
$ cd vms/api
$ CAN_NETWORK_MAPPINGS=ovcs:can0,leaf_drive:vcan1,polo_drive:vcan2,orion_bms:vcan3,misc:vcan4 iex -S mix phx.server
```

### Building a VMS firmware with custom VCAN and SPI interfaces:

```sh
$ CAN_NETWORK_MAPPINGS=ovcs:spi0.0,leaf_drive:vcan0,polo_drive:vcan1,orion_bms:vcan2,misc:vcan3 ./ovcs-cli build vms
```

### Uploading the VMS:

```sh
$ ./ovcs-cli upload vms
```

Next: [Testing generic controller](./testing_generic_controllers.md)