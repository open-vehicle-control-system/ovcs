---
title: Write a bridge
description: When to write a bridge rather than a VMS component, what a bridge library is made of, a worked bridge with its test, and how to declare it in your vehicle.
---

A bridge connects your vehicle to a world it has no CAN link to: a serial protocol, a network service, a sensor on a USB port. This page builds a complete one, `BoardTemperatureBridge`, which reads its board's temperature and publishes it on the OVCS bus. It is small on purpose. Every bridge the framework ships, the [radio control bridge](./radio_control.md) and the [ROS bridge](./ros.md), follows the same recipe with more components.

## Bridge, component or child

Pick the smallest thing that fits:

- **A VMS component** when the hardware is on a CAN bus the VMS already sees, or on a [generic controller](../generic_controllers/README.md)'s pins. See [Add a component](../vms/add_a_component.md).
- **A bridge** when the data lives outside CAN and needs its own board, or a board shared with other bridges: a radio receiver on a UART, a ROS graph, a lidar on USB.
- **A child of a bridge firmware entry** when a library only reads the bus and has no per-vehicle wiring of its own. The [bus gateway](../bus/gateway.md) runs that way, listed in an entry's `children`.

A bridge never commands an actuator. Commands it produces go to the VMS as CAN frames on the `ovcs` bus. There, the VMS checks their freshness, and its [control levels](../vms/how_it_works.md#control-levels) decide whether they are in force.

Everything a bridge publishes on its own bus stays on its own board: a broadcast is [node-local](../bus/README.md#scope).

## What a bridge is made of

- **A Mix project under `bridges/<name>/`** that depends on [`ovcs_bridge`](../../libraries/ovcs_bridge/README.md). That one dependency brings `ovcs_bus`, `ovcs_vehicle` and `cantastic`.
- **A module implementing [`OvcsBridge`](../../libraries/ovcs_bridge/lib/ovcs_bridge.ex).** `children/0` returns the child specs the bridge firmware supervises. The optional `apply_runtime_config/2` runs before any application starts, for a dependency that reads its application environment once at boot. The behaviour's moduledoc documents both.
- **A configuration callback on your vehicle module**, with a `:host` and a `:target` arm, returning the bridge's config struct. The bridge reads the active vehicle from `:ovcs_vehicle`'s `:module` environment, which the bridge firmware sets at boot.

## A worked bridge

`bridges/board_temperature_bridge/mix.exs` declares the library and its one dependency:

```elixir
defmodule BoardTemperatureBridge.MixProject do
  use Mix.Project

  def project do
    [
      app: :board_temperature_bridge,
      version: "0.1.0",
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application, do: [extra_applications: [:logger]]

  defp deps do
    [{:ovcs_bridge, path: "../../libraries/ovcs_bridge"}]
  end
end
```

`lib/board_temperature_bridge.ex` holds the config struct, the behaviour your vehicle implements, and `children/0`:

```elixir
defmodule BoardTemperatureBridge.Config do
  @moduledoc "Per-vehicle configuration for `BoardTemperatureBridge`."
  defstruct interval_ms: 1_000, path: "/sys/class/thermal/thermal_zone0/temp"

  @type t :: %__MODULE__{interval_ms: pos_integer(), path: String.t()}
end

defmodule BoardTemperatureBridge do
  @moduledoc """
  Publishes the bridge board's temperature on the OVCS bus as
  `:board_temperature`. Vehicles implement
  `c:board_temperature_bridge_config/1` to configure it.
  """
  @behaviour OvcsBridge

  @callback board_temperature_bridge_config(:host | :target) :: BoardTemperatureBridge.Config.t()

  # Read at compile time: on a Nerves device Mix.target() returns :host at runtime.
  @arm if Mix.target() == :host, do: :host, else: :target

  @impl OvcsBridge
  def children do
    [{BoardTemperatureBridge.Publisher, vehicle().board_temperature_bridge_config(@arm)}]
  end

  defp vehicle, do: Application.fetch_env!(:ovcs_vehicle, :module)
end
```

The arm is fixed when the library compiles, because `Mix.target()` means nothing on the device. That is what lets your vehicle return a dummy driver for `./ovcs run` and the real one for the burned image.

`lib/board_temperature_bridge/publisher.ex` does the work, publishing a bus message as any [VMS component](../vms/how_it_works.md#the-component-pattern) does:

```elixir
defmodule BoardTemperatureBridge.Publisher do
  @moduledoc "Reads the board temperature every `interval_ms` and broadcasts it."
  use GenServer
  alias OvcsBus, as: Bus

  def start_link(config), do: GenServer.start_link(__MODULE__, config, name: __MODULE__)

  @impl GenServer
  def init(config) do
    {:ok, _timer} = :timer.send_interval(config.interval_ms, :tick)
    {:ok, config}
  end

  @impl GenServer
  def handle_info(:tick, config) do
    with {:ok, raw} <- File.read(config.path),
         {millidegrees, _} <- Integer.parse(raw) do
      Bus.broadcast("messages", %Bus.Message{
        name: :board_temperature,
        value: millidegrees / 1000,
        source: __MODULE__,
        unit: Bus.Units.celsius()
      })
    end

    {:noreply, config}
  end
end
```

A reading that fails publishes nothing, so a consumer sees the signal go stale instead of a wrong value.

### Test it

The test drives the publisher against a file standing in for the sensor. `test/test_helper.exs` starts the bus:

```elixir
Application.ensure_all_started(:ovcs_bus)
ExUnit.start()
```

```elixir
defmodule BoardTemperatureBridge.PublisherTest do
  use ExUnit.Case, async: false

  test "publishes the board temperature in degrees Celsius" do
    path = Path.join(System.tmp_dir!(), "board_temperature")
    File.write!(path, "41250\n")
    OvcsBus.subscribe("messages")

    start_supervised!(
      {BoardTemperatureBridge.Publisher,
       %BoardTemperatureBridge.Config{interval_ms: 10, path: path}}
    )

    assert_receive %OvcsBus.Message{name: :board_temperature, value: 41.25, unit: "°C"}
  end
end
```

Run it with `mix test --no-start`, as CI does for every bridge library. Without `--no-start`, Mix starts Cantastic, which refuses to boot with no CAN configuration.

## Talk to the CAN bus

This bridge only publishes on its own bus. A bridge that sends to the VMS, or reads what the VMS emits, uses Cantastic on the `ovcs` network, exactly as a VMS component does: see [Receiving frames](../vms/add_a_component.md#receiving-frames) and [Emitting frames](../vms/add_a_component.md#emitting-frames).

The frames go in your vehicle's topology for that bridge firmware, `priv/can/bridges/<id>.yml` by default (see [Bridge firmwares](./README.md#bridge-firmwares)). They can import the shared specs from `ovcs_can`.

A command frame should carry a sequence number that changes with every sample, as the ROS commands do. The VMS can then tell a live command from a stuck one.

## List it in the bridge firmware

No firmware depends on a vehicle as a Mix dependency: vehicles are loaded at boot with `Code.prepend_path`. So a bridge library can't arrive transitively through your vehicle. List it in [`bridges/firmware/mix.exs`](../../bridges/firmware/mix.exs), gated to the targets it supports:

```elixir
{:board_temperature_bridge,
 path: "../board_temperature_bridge",
 targets: [:host, :ovcs_base_can_system_rpi4, :rpi5],
 runtime: Mix.target() != :host},
```

On the host every bridge matches, so all of them sit in the firmware's dependency tree at once. `runtime: false` there keeps OTP from starting each one's application, and leaves `OvcsBridge.Supervisor` to start only the bridges the running entry lists. On a target, only the bridges gated to it are compiled.

## Declare it in your vehicle

Implement the callback on your vehicle's top-level module:

```elixir
@behaviour BoardTemperatureBridge

@impl BoardTemperatureBridge
def board_temperature_bridge_config(_arm), do: %BoardTemperatureBridge.Config{}
```

Then bundle the bridge in an entry of `bridge_firmwares/0`, alone or next to others:

```elixir
"telemetry" => %{
  target: :ovcs_base_can_system_rpi4,
  bridges: [BoardTemperatureBridge],
  default_can_mapping: %{host: "ovcs:vcan0", target: "ovcs:spi0.0"}
}
```

`./ovcs run <vehicle>` now starts a `<vehicle>-bridge-telemetry` BEAM, and `./ovcs build <vehicle> bridge-telemetry` builds its image.

The [bus gateway](../bus/gateway.md) collects from every node of the mesh. If your vehicle runs it, the signal shows up in its dashboard, on MQTT and at `/api/signals?filter[name]=board_temperature`.

## Where next

- [Bridges](./README.md): the bridge firmware entry, its targets and its boot sequence.
- [ROS bridge](./ros.md): a bridge with a component catalogue, consumers and publishers.
- [Add a component](../vms/add_a_component.md): the CAN calls a bridge uses to talk to the VMS.
