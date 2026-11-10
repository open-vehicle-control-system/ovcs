defmodule SimulatorCore.Hardware do
  @moduledoc """
  Stands in for a vehicle's hardware against a simulator, so the VMS
  drives the simulated vehicle over CAN as it drives the real one.
  **Simulation only.**

  Every `@period_ms` it collects the actuations of the vehicle's
  simulated components (`SimulatorCore.SimulatedComponent`),
  advances `SimulatorCore.Vehicle`, lets each report the motion as
  the hardware it stands in for would, and hands the vehicle's motion
  to the world (`SimulatorCore.World`), which moves it; the VMS learns
  how far it went only from the simulated components' telemetry.

  The telemetry measures the simulated wheels, as the vehicle's motor
  and shaft sensors do. How far they turned is what the world last
  reported, which it integrates, and how fast is that distance per
  second of the wall clock the VMS measures against (see
  `SimulatorCore.Vehicle`): the counters match the simulator, and the
  rates match the counters, however fast the simulator runs. The
  reports are cumulative, so samples arriving late or in bursts lose
  nothing. Before the first one, or from a world that reports none, it
  reports its own commanded motion instead.

  ## Options

    * `:vehicle` (required) — `SimulatorCore.Vehicle.new/1`'s
      parameters.
    * `:simulated_components` (required) — `{module, opts}` per
      simulated component.
    * `:world` (required) — `{module, opts}`, a `SimulatorCore.World`.

  The CAN topology of the firmware running it must declare every frame
  the simulated components read and emit, the other way round from the
  VMS's.
  """
  use GenServer

  alias Cantastic.Frame
  alias SimulatorCore.{SimulatedComponent, Vehicle}

  require Logger

  @period_ms 20

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl GenServer
  def init(opts) do
    opts = Map.new(opts)

    components =
      opts |> Map.fetch!(:simulated_components) |> Enum.map(&SimulatedComponent.start/1)

    {world, world_opts} = Map.fetch!(opts, :world)
    world_state = world.init(world_opts)

    {:ok, _timer} = :timer.send_interval(@period_ms, :step)

    Logger.info(
      "#{__MODULE__}: emulating #{Enum.map_join(components, ", ", &inspect(&1.module))}"
    )

    {:ok,
     %{
       vehicle: Vehicle.new(Map.fetch!(opts, :vehicle)),
       components: components,
       world: {world, world_state},
       last_step_ms: now_ms(),
       wheel_turns: nil,
       wheel_turns_read: nil
     }}
  end

  @impl GenServer
  def handle_info(:step, state) do
    now_ms = now_ms()
    dt_s = (now_ms - state.last_step_ms) / 1000

    actuations =
      Enum.flat_map(state.components, &SimulatedComponent.actuations(&1, state.vehicle, now_ms))

    wheel_turns_step = wheel_turns_step(state.wheel_turns, state.wheel_turns_read)
    vehicle = Vehicle.step(state.vehicle, actuations, dt_s, wheel_turns_step)
    components = Enum.map(state.components, &SimulatedComponent.report(&1, vehicle, now_ms))
    {world, world_state} = state.world
    :ok = world.drive(vehicle, world_state)

    {:noreply,
     %{
       state
       | vehicle: vehicle,
         components: components,
         last_step_ms: now_ms,
         wheel_turns_read: state.wheel_turns
     }}
  end

  def handle_info({:handle_frame, %Frame{} = frame}, state) do
    now_ms = now_ms()
    components = Enum.map(state.components, &SimulatedComponent.handle_frame(&1, frame, now_ms))
    {:noreply, %{state | components: components}}
  end

  def handle_info(message, %{world: {world, world_state}} = state) do
    case world.wheel_turns(message, world_state) do
      nil -> {:noreply, state}
      turns -> {:noreply, %{state | wheel_turns: turns}}
    end
  end

  @doc """
  How far the wheels turned since the last tick, from the latest sample
  and the one the last tick read: nil before any sample, 0 for the first.
  Pure.
  """
  def wheel_turns_step(nil, _read), do: nil
  def wheel_turns_step(_turns, nil), do: 0.0
  def wheel_turns_step(turns, read), do: turns - read

  defp now_ms, do: System.monotonic_time(:millisecond)
end
