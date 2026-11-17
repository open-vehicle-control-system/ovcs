defmodule SimulatorCore.Hardware do
  @moduledoc """
  Stands in for a vehicle's hardware against a simulator, so the VMS
  drives the simulated vehicle over CAN as it drives the real one.
  **Simulation only.**

  Every `@period_ms` it collects the efforts of the vehicle's simulated
  components (`SimulatorCore.SimulatedComponent`), combines them
  (`SimulatorCore.Efforts`), and hands them to the one model that moves
  the vehicle: the world (`SimulatorCore.World`) when there is one,
  `SimulatorCore.FlatGround` otherwise. Each simulated component then
  measures the world's state (`SimulatorCore.WorldState`) as the
  hardware it stands in for would: the VMS learns how the vehicle moved
  only from that telemetry. Components not yet on `efforts/3` and
  `measure/3` run through `SimulatorCore.SimulatedComponent.Legacy`.

  An external world reports its state in messages, as its own clock
  runs; the components measure the latest one, and a vehicle at rest
  before the first.

  ## Options

    * `:vehicle` (required) — `SimulatorCore.FlatGround.new/1`'s
      parameters: `:wheel_radius_m` is the world's too, and
      `:mass_kg` turns old components' accelerations into torques.
    * `:simulated_components` (required) — `{module, opts}` per
      simulated component.
    * `:world` — `{module, opts}`, a `SimulatorCore.World`. Without
      one, `SimulatorCore.FlatGround` moves the vehicle.

  The CAN topology of the firmware running it must declare every frame
  the simulated components read and emit, the other way round from the
  VMS's.
  """
  use GenServer

  alias Cantastic.Frame
  alias SimulatorCore.{Efforts, FlatGround, SimulatedComponent, WorldState}
  alias SimulatorCore.SimulatedComponent.Legacy

  require Logger

  @period_ms 20

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl GenServer
  def init(opts) do
    opts = Map.new(opts)
    vehicle = Map.fetch!(opts, :vehicle)

    components =
      opts |> Map.fetch!(:simulated_components) |> Enum.map(&SimulatedComponent.start/1)

    {:ok, _timer} = :timer.send_interval(@period_ms, :step)

    Logger.info(
      "#{__MODULE__}: emulating #{Enum.map_join(components, ", ", &inspect(&1.module))}"
    )

    world = init_world(Map.get(opts, :world))

    {:ok,
     %{
       components: components,
       world: world,
       ground: if(world, do: nil, else: FlatGround.new(vehicle)),
       world_state: WorldState.at_rest(Map.fetch!(vehicle, :wheel_radius_m)),
       mass_kg: Map.fetch!(vehicle, :mass_kg),
       motion: nil,
       wheel_angle_rad: nil,
       steering_rad: 0.0,
       last_step_ms: now_ms()
     }}
  end

  @impl GenServer
  def handle_info(:step, state) do
    now_ms = now_ms()
    dt_s = (now_ms - state.last_step_ms) / 1000

    efforts =
      state.components
      |> Enum.flat_map(&SimulatedComponent.efforts(&1, tick(state), now_ms))
      |> Efforts.combine(state.steering_rad)

    state =
      %{state | steering_rad: efforts.steering_rad, last_step_ms: now_ms}
      |> move(efforts, dt_s)
      |> measured_motion()

    components = Enum.map(state.components, &SimulatedComponent.measure(&1, tick(state), now_ms))

    {:noreply, %{state | components: components}}
  end

  def handle_info({:handle_frame, %Frame{} = frame}, state) do
    now_ms = now_ms()
    components = Enum.map(state.components, &SimulatedComponent.handle_frame(&1, frame, now_ms))
    {:noreply, %{state | components: components}}
  end

  def handle_info(_message, %{world: nil} = state), do: {:noreply, state}

  def handle_info(message, %{world: {world, world_opts}} = state) do
    case world.world_state(message, world_opts) do
      nil ->
        {:noreply, state}

      {world_state, world_opts} ->
        {:noreply, %{state | world: {world, world_opts}, world_state: world_state}}
    end
  end

  defp move(%{world: nil} = state, efforts, dt_s) do
    ground = FlatGround.step(state.ground, efforts, dt_s)
    %{state | ground: ground, world_state: FlatGround.world_state(ground)}
  end

  defp move(%{world: {world, world_opts}} = state, efforts, dt_s),
    do: %{state | world: {world, world.actuate(efforts, dt_s, world_opts)}}

  defp tick(state) do
    %{
      world: state.world_state,
      motion: state.motion || elem(Legacy.motion(state.world_state, nil), 0),
      mass_kg: state.mass_kg,
      wheel_radius_m: state.world_state.wheel_radius_m
    }
  end

  defp measured_motion(state) do
    {motion, wheel_angle_rad} = Legacy.motion(state.world_state, state.wheel_angle_rad)
    %{state | motion: motion, wheel_angle_rad: wheel_angle_rad}
  end

  defp init_world(nil), do: nil
  defp init_world({world, world_opts}), do: {world, world.init(world_opts)}

  defp now_ms, do: System.monotonic_time(:millisecond)
end
