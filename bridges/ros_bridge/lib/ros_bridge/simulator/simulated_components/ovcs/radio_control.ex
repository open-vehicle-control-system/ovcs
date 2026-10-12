defmodule RosBridge.Simulator.SimulatedComponents.OVCS.RadioControl do
  @moduledoc """
  An RC receiver's channels on `radio_control_channels0` and `1`
  (`0x2A0`, `0x2A1`), what `RadioControlBridge` emits on the vehicle.

  The channels follow a script rather than a transmitter: `:channels`
  from the start, then each of `:steps` at its time. Scripting the
  control-level switches through their positions in order is how a
  simulated run reaches `:ros` without a human, through the same
  transitions the manager requires on the vehicle.

  The script's clock starts when the `:start_on` frame arrives, so the
  switches move only once the VMS is there to see them. When that frame
  stops for `:rewind_after_ms`, the script goes back to its start: a
  restarted VMS boots at its default level and has to see the switches
  move again.

  ## Options

    * `:network` (`:ovcs`).
    * `:channels` (`%{}`) — channel number to pulse width in µs at the
      start; an absent channel reads 0.
    * `:steps` (`[]`) — `{after_ms, %{channel => pulse}}`, applied once
      `after_ms` has passed on the script's clock.
    * `:start_on` (`{:ovcs, "vms_status"}`) — the frame that starts it.
    * `:rewind_after_ms` (`1_000`).
  """
  @behaviour RosBridge.Simulator.SimulatedComponent

  @impl RosBridge.Simulator.SimulatedComponent
  def init(opts) do
    opts = Map.new(opts)

    state = %{
      network: Map.get(opts, :network, :ovcs),
      channels: Map.get(opts, :channels, %{}),
      steps: Enum.sort_by(Map.get(opts, :steps, []), &elem(&1, 0)),
      rewind_after_ms: Map.get(opts, :rewind_after_ms, 1_000),
      started_at_ms: nil,
      last_seen_ms: nil
    }

    {state, [Map.get(opts, :start_on, {:ovcs, "vms_status"})], updates(state, state.channels)}
  end

  @impl RosBridge.Simulator.SimulatedComponent
  def handle_frame(_name, _signals, state, now_ms),
    do: %{state | started_at_ms: state.started_at_ms || now_ms, last_seen_ms: now_ms}

  @impl RosBridge.Simulator.SimulatedComponent
  def step(state, _vehicle, _dt_s, now_ms) do
    state =
      if state.started_at_ms && now_ms - state.last_seen_ms > state.rewind_after_ms,
        do: %{state | started_at_ms: nil},
        else: state

    {state, updates(state, channels_at(state, now_ms))}
  end

  @doc "The channels the script gives at `now_ms`."
  def channels_at(%{started_at_ms: nil} = state, _now_ms), do: state.channels

  def channels_at(state, now_ms) do
    elapsed_ms = now_ms - state.started_at_ms

    state.steps
    |> Enum.take_while(fn {after_ms, _} -> after_ms <= elapsed_ms end)
    |> Enum.reduce(state.channels, fn {_, changes}, channels -> Map.merge(channels, changes) end)
  end

  defp updates(state, channels) do
    [
      {state.network, "radio_control_channels0", signals(channels, 1..4)},
      {state.network, "radio_control_channels1", signals(channels, 5..8)}
    ]
  end

  defp signals(channels, range),
    do: Map.new(range, fn channel -> {"channel#{channel}", Map.get(channels, channel, 0)} end)
end
