defmodule SimulatorCore.SimulatedComponents.Volkswagen.Polo9N.IgnitionLock do
  @moduledoc """
  A Volkswagen Polo 9N ignition lock, the inverse of
  `VmsCore.Components.Volkswagen.Polo9N.IgnitionLock`: the key's
  position on `key_status`.

  The key follows a script rather than a driver: off, then each of
  `:steps` at its time. The script's clock starts when the VMS's
  `vms_status` arrives, so the key turns only once the VMS is there to
  see it. When `vms_status` stops for `:rewind_after_ms`, the key goes
  back off and the script to its start: a restarted VMS has to see the
  key turn again.

  `key_status` emits with `ovcs_can`'s
  `volkswagen/polo_9n/simulated/0x570_key_status.yml`, which gives the
  shared definition a frequency and one value per key state.

  ## Options

    * `:network` (required) — the ignition lock's network.
    * `:steps` (`[]`) — `{after_ms, position}`, with `position` one of
      `:off`, `:on` and `:start`, the `:contact` values the VMS
      publishes.
    * `:start_on` (`{:ovcs, "vms_status"}`) — the frame that starts it.
    * `:rewind_after_ms` (`1_000`).
  """
  @behaviour SimulatorCore.SimulatedComponent

  @key_states %{off: "contact_off", on: "contact_on", start: "start_engine"}

  @impl SimulatorCore.SimulatedComponent
  def init(opts) do
    opts = Map.new(opts)

    state = %{
      network: Map.fetch!(opts, :network),
      steps: Enum.sort_by(Map.get(opts, :steps, []), &elem(&1, 0)),
      rewind_after_ms: Map.get(opts, :rewind_after_ms, 1_000),
      started_at_ms: nil,
      last_seen_ms: nil
    }

    {state, [Map.get(opts, :start_on, {:ovcs, "vms_status"})], [key_status(state, :off)]}
  end

  @impl SimulatorCore.SimulatedComponent
  def handle_frame(_name, _signals, state, now_ms),
    do: %{state | started_at_ms: state.started_at_ms || now_ms, last_seen_ms: now_ms}

  @impl SimulatorCore.SimulatedComponent
  def report(state, _vehicle, now_ms) do
    state =
      if state.started_at_ms && now_ms - state.last_seen_ms > state.rewind_after_ms,
        do: %{state | started_at_ms: nil},
        else: state

    {state, [key_status(state, position_at(state, now_ms))]}
  end

  defp position_at(%{started_at_ms: nil}, _now_ms), do: :off

  defp position_at(state, now_ms) do
    elapsed_ms = now_ms - state.started_at_ms

    state.steps
    |> Enum.take_while(fn {after_ms, _} -> after_ms <= elapsed_ms end)
    |> Enum.reduce(:off, fn {_, position}, _ -> position end)
  end

  defp key_status(state, position),
    do: {state.network, "key_status", %{"key_state" => Map.fetch!(@key_states, position)}}
end
