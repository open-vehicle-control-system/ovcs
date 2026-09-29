---
title: Your first vehicle
description: Scaffold a vehicle, give it a CAN frame in and a CAN frame out, a component that links them and a dashboard block, and drive all of it on virtual CAN.
---

The [Quickstart](./quickstart.md) boots a reference vehicle. This page builds yours. You scaffold a package, see why it reports `FAILURE`, then add one feature end to end: a coolant temperature sensor that the VMS reads from the `ovcs` bus, a component that decides when the radiator fan must run, a frame that requests the fan, and a dashboard block that shows it all and lets you change the threshold. Everything runs on your laptop on virtual CAN. The last section points to flashing it on a Raspberry Pi.

You need the toolchain from [Getting started](./getting_started.md): `./ovcs doctor` green and can-utils installed. The example is small on purpose; every piece of it is the same recipe the framework's own drivers follow.

## Scaffold it

```sh
./ovcs new my_car
./ovcs vehicles
```

`./ovcs new` renders the template in [`libraries/ovcs_vehicle/priv/templates/vehicle/`](../libraries/ovcs_vehicle/priv/templates/vehicle) into `vehicles/my_car/` and prints the Nerves targets it picked (`ovcs_base_can_system_rpi4` for the VMS, `ovcs_base_can_system_rpi5` for the infotainment). `--no-infotainment` gives a VMS-only vehicle and `--no-bridges` drops the bridge firmware dependency; the defaults are fine for this page. `./ovcs vehicles` now lists `my_car` next to the reference vehicles. Nothing in the framework knows about it: the firmwares load it at boot because `VEHICLE=MyCar`.

## What you got

```text
vehicles/my_car/
  lib/my_car.ex                        the OvcsVehicle module: name, composers, targets, bridges
  lib/my_car/vms.ex                    your VMS state machine: ready_to_drive and vms_status
  lib/my_car/vms/composer.ex           VmsCore.Vehicle: children, CAN config, CAN mapping
  lib/my_car/vms/composer/…            dashboard pages and the generic controller map
  lib/my_car/infotainment.ex           the head unit's status, read from the ovcs bus
  lib/my_car/infotainment/composer/…   head unit pages and blocks
  priv/can/vms.yml                     the VMS topology: networks and the frames on each
  priv/can/infotainment.yml            the infotainment topology
  priv/can/generic_controller/         the example controller's frames, 0x701, 0x702, 0x704
  priv/firmware/{vms,infotainment}/    config.txt, cmdline-a.txt, cmdline-b.txt per image
  .env.exs.example                     secrets for hardware builds
```

The VMS composer starts three children: an example generic controller (`OVCS.GenericController` named `MyCar.Vms.ExampleController`), `VmsCore.Status`, and `MyCar.Vms`. Its CAN mapping is `ovcs:vcan0` on the host and `ovcs:spi0.0` on the Pi. [Your vehicle package](./vehicle_package.md) explains each callback; this page only changes the composer, the topology and the dashboard page.

## Boot it and read the FAILURE

```sh
./ovcs run my_car
```

The first run compiles every firmware project the vehicle uses, and with bridges enabled that includes native dependencies such as `evision`; it takes a while once, then it's incremental. `./ovcs run` creates `vcan0`, starts one BEAM per role (`my-car-vms` and `my-car-infotainment`, which join one Erlang mesh), and starts the dashboard add-on. Open `http://localhost:5173`: the Status page has one block, VMS, and it reads `Status FAILURE` and `Ready to drive false`.

That is the scaffold working as written. `MyCar.Vms` computes both values from one fact, whether the example controller is alive, and there is no controller on your laptop. The controller driver watches its alive frame, `0x701`, which a real board sends every 100 ms. Pretend to be the board:

```sh
cangen vcan0 -I 701 -L 4 -D 00020000 -g 100
```

The payload is the alive frame's layout from [`0x7X1_alive_signals.yml`](../libraries/ovcs_can/priv/can/components/ovcs/generic_controller/0x7X1_alive_signals.yml): byte 0 a counter, byte 1 the status (`0x02`, `OK`), then two expansion-board error bytes. Within a second the block reads `OK` and `true`. Stop `cangen` and a few seconds later it falls back to `FAILURE`: the controller's received-frame watchdog declares the frame missing after ten late frames, the `allowed_missing_frames` in `0x701_example_controller_alive.yml`. Your vehicle's real `ready_to_drive` rule goes in `compute_ready_to_drive/1` in `lib/my_car/vms.ex`; keep the controller check if you keep a controller.

## Declare the frames

The feature needs two frames on the `ovcs` bus: `coolant_status` (`0x300`), sent by a sensor node and received by the VMS, and `fan_request` (`0x301`), emitted by the VMS. Neither id is used by the framework's shared specs. Put vehicle-specific frames in your package; the shared library [`ovcs_can`](../libraries/ovcs_can/priv/can/components) is for components several vehicles use.

```yaml
# vehicles/my_car/priv/can/cooling/0x300_coolant_status.yml
---
name: coolant_status
id: 0x300
frequency: 100
allowed_frequency_leeway: 50
allowed_missing_frames: 5
signals:
  - name: coolant_temperature
    kind: decimal
    unit: °C
    value_start: 0
    value_length: 8
    offset: "-40"
```

```yaml
# vehicles/my_car/priv/can/cooling/0x301_fan_request.yml
---
name: fan_request
id: 0x301
frequency: 100
signals:
  - name: fan_on
    kind: enum
    value_start: 0
    value_length: 8
    mapping:
      0x00: false
      0x01: true
```

One byte of temperature with a -40 offset covers -40 °C to 215 °C: raw `0x6E` (110) is 70 °C. `frequency` is the period in milliseconds: for a received frame it is what the watchdog expects, for an emitted one it is how often the VMS sends it. Then import both in `priv/can/vms.yml`, under the `ovcs` network. The path is relative to the importing file:

```yaml
can_networks:
  ovcs:
    bitrate: 1000000
    emitted_frames:
      # … the scaffold's frames stay
      - import!:cooling/0x301_fan_request.yml
    received_frames:
      # … the scaffold's frames stay
      - import!:cooling/0x300_coolant_status.yml
```

[CAN frames and topology](./can_frames.md) documents every key, and how `value_start` compares with a DBC start bit if you are porting an existing message set.

## Add a component

A component is a GenServer the composer starts. This one subscribes to `coolant_status`, watches it for silence, configures the `fan_request` emitter, decides on a 100 ms loop, and publishes its state on the bus so the dashboard can show it:

```elixir
# vehicles/my_car/lib/my_car/vms/coolant_fan.ex
defmodule MyCar.Vms.CoolantFan do
  @moduledoc """
  Reads the coolant temperature from `coolant_status` and asks for the
  radiator fan through `fan_request` when it crosses a threshold.
  """
  use GenServer
  alias Cantastic.{Emitter, Frame, ReceivedFrameWatcher, Receiver, Signal}
  alias OvcsBus, as: Bus

  @loop_period 100
  @hysteresis Decimal.new(5)

  def start_link(args), do: GenServer.start_link(__MODULE__, args, name: __MODULE__)

  @impl true
  def init(%{on_threshold: on_threshold}) do
    :ok = Receiver.subscribe(self(), :ovcs, "coolant_status")
    :ok = ReceivedFrameWatcher.enable(:ovcs, "coolant_status")

    :ok =
      Emitter.configure(:ovcs, "fan_request", %{
        parameters_builder_function: :default,
        initial_data: %{"fan_on" => false},
        enable: true
      })

    {:ok, timer} = :timer.send_interval(@loop_period, :loop)

    {:ok,
     %{
       loop_timer: timer,
       on_threshold: Decimal.new(on_threshold),
       coolant_temperature: nil,
       fan_on: false,
       sensor_alive: false
     }}
  end

  @impl true
  def handle_info({:handle_frame, %Frame{name: "coolant_status", signals: signals}}, state) do
    %{"coolant_temperature" => %Signal{value: temperature}} = signals
    {:noreply, %{state | coolant_temperature: temperature}}
  end

  def handle_info(:loop, state) do
    {:ok, alive} = ReceivedFrameWatcher.is_alive?(:ovcs, "coolant_status")

    state =
      state
      |> track_sensor(alive)
      |> decide_fan()
      |> emit()
      |> broadcast()

    {:noreply, state}
  end

  def trigger_action("set_on_threshold", %{"value" => value}) do
    GenServer.call(__MODULE__, {:set_on_threshold, Decimal.new(value)})
  end

  @impl true
  def handle_call({:set_on_threshold, threshold}, _from, state) do
    {:reply, :ok, %{state | on_threshold: threshold}}
  end

  # A sensor that went quiet has no reading: don't show a stale one.
  defp track_sensor(state, true), do: %{state | sensor_alive: true}
  defp track_sensor(state, false), do: %{state | sensor_alive: false, coolant_temperature: nil}

  # No reading: run the fan to be safe.
  defp decide_fan(%{coolant_temperature: nil} = state), do: %{state | fan_on: true}

  defp decide_fan(state) do
    off_threshold = Decimal.sub(state.on_threshold, @hysteresis)

    cond do
      Decimal.compare(state.coolant_temperature, state.on_threshold) != :lt ->
        %{state | fan_on: true}

      Decimal.compare(state.coolant_temperature, off_threshold) == :lt ->
        %{state | fan_on: false}

      true ->
        state
    end
  end

  defp emit(state) do
    :ok = Emitter.update(:ovcs, "fan_request", fn data -> %{data | "fan_on" => state.fan_on} end)
    state
  end

  defp broadcast(state) do
    for {name, value} <- [
          coolant_temperature: state.coolant_temperature,
          fan_on: state.fan_on,
          sensor_alive: state.sensor_alive,
          on_threshold: state.on_threshold
        ] do
      Bus.broadcast("messages", %Bus.Message{name: name, value: value, source: __MODULE__})
    end

    state
  end
end
```

Three things are worth reading twice. Decoded `decimal` signals are `Decimal` structs, so compare them with `Decimal.compare/2`, not `>`. The emitter sends on its own timer; `Emitter.update/3` only changes the data it sends next. And a sensor that stops talking is treated as a missing reading, not as its last value: the fan runs. That is a choice for this example; your safe state depends on your hardware. [Writing a component](./writing_components.md) covers each call, the watchdog thresholds, and the framework drivers you can reuse instead of writing your own.

Start it from the composer's `children/0`, before `{Vms, []}`:

```elixir
{Vms.CoolantFan, %{on_threshold: 90}},
```

## Put it on the dashboard

The dashboard page is a map of blocks. Add a `cooling` block next to the scaffold's `vms-status` block in `lib/my_car/vms/composer/dashboard/dashboard_page.ex`:

```elixir
"cooling" => %{
  order: 1,
  name: "Cooling",
  type: "table",
  rows: [
    %{type: :metric, name: "Coolant temperature", module: Vms.CoolantFan, key: :coolant_temperature},
    %{type: :metric, name: "Sensor alive", module: Vms.CoolantFan, key: :sensor_alive},
    %{type: :metric, name: "Fan on", module: Vms.CoolantFan, key: :fan_on},
    %{
      type: :action,
      name: "Fan on above (°C)",
      input_type: :number,
      step: "1",
      input_name: "Set",
      module: Vms.CoolantFan,
      action: "set_on_threshold",
      status_metric_key: :on_threshold
    }
  ]
}
```

A `:metric` row names the message's `source` and `name`: every value your component broadcasts is already a metric. The `:action` row posts to `/api/actions`, which calls `MyCar.Vms.CoolantFan.trigger_action("set_on_threshold", %{"value" => "…"})`; the value arrives as a string, and the function must return `:ok`. [Dashboard pages](./dashboard_pages.md) lists every block and row type.

## Drive it on virtual CAN

Stop `./ovcs run` with `Ctrl+C` and start it again so the package recompiles. With no sensor on the bus, the block shows no temperature, `Sensor alive false` and `Fan on true`, and the VMS is already asking for the fan:

```sh
candump vcan0,301:7FF
#  vcan0  301   [1]  01
```

Be the sensor. Send 70 °C (raw `0x6E`) every 100 ms in another terminal:

```sh
cangen vcan0 -I 300 -L 1 -D 6E -g 100
```

`Sensor alive` turns `true`, the temperature reads `70.00` and `fan_request` drops to `00`. Stop `cangen`: about two seconds later the watchdog declares the frame missing, the temperature goes blank and the fan request returns to `01`. Send 95 °C (`-D 87`) and it stays on. Type `65` into "Fan on above (°C)" and press Set while 70 °C streams: the threshold row reads 65 and the fan comes on. The same request from a shell, which is what the button sends:

```sh
curl -X POST http://localhost:4000/api/actions \
  -H 'content-type: application/json' \
  -d '{"module":"Elixir.MyCar.Vms.CoolantFan","action":"set_on_threshold","value":"65"}'
```

`./ovcs attach my_car` shows the same traffic decoded, with both frames by name, next to the logs and the bus messages. [Testing with CAN](./testing_with_can.md) goes further: replaying captures, watching what the VMS emits, and testing components without a bus.

## Put it on hardware

The same package boots on a Raspberry Pi 4 with a CAN interface. The steps are in [Running on hardware](./running_hardware.md):

1. Check the target side of the composer: `default_can_mapping(:target)` is `ovcs:spi0.0`, and `priv/firmware/vms/config.txt` must load the overlay that creates that interface for your HAT. [Hardware you need](./hardware_you_need.md) gives the `config.txt` line for common HATs.
2. Copy `.env.exs.example` to `.env.exs` and fill in your SSH key and Wi-Fi.
3. `./ovcs host-keys generate my_car`, then `./ovcs build my_car vms` and `./ovcs burn my_car vms`.
4. Boot the Pi and `./ovcs attach my_car`.

To replace the fake alive frames with a real board, flash the generic controller firmware on an Arduino and adopt it: [Generic controllers](./generic_controllers.md). The example controller is controller 0, on `0x701`–`0x709`.

## Next steps

- [Writing a component](./writing_components.md): every Cantastic and bus call, and the framework drivers you can reuse.
- [CAN frames and topology](./can_frames.md): the YAML format, imports, and DBC bit numbering.
- [Dashboard pages](./dashboard_pages.md): charts, buttons, toggles and the head unit's blocks.
- [Your vehicle package](./vehicle_package.md): the full contract, bridges and control levels.
