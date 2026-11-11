defmodule OvcsVehicle.ClockSync do
  @moduledoc """
  Restarts `ntpd` while the network is up and the clock is not synchronized.

  BusyBox `ntpd` schedules its queries on the wall clock. A board whose
  RTC driver probes after `ntpd` has started, such as the Arduino
  VENTUNO Q's PMIC RTC, steps the clock back to 1970, and `ntpd` then
  sleeps until its next query time comes round again: decades. A
  restarted `ntpd` schedules from the clock as it now is, and syncs.

  A check restarts `ntpd` when VintageNet's global connection is
  `:internet` and `NervesTime.synchronized?/0` is false. It runs when the
  connection becomes `:internet` and every `:interval_ms` (2 minutes)
  after the last check, which covers a network that is up before the
  step. The interval leaves a first sync time to finish.

  Options, for tests: `:connected?`, `:synchronized?`, `:restart` and
  `:subscribe`, functions of no argument, and `:interval_ms`.

  Wired in only on target, like `OvcsVehicle.FirmwareValidator`:

      children =
        if Nerves.Runtime.mix_target() == :host,
          do: children,
          else: [OvcsVehicle.ClockSync | children]
  """

  use GenServer

  require Logger

  @interval_ms 120_000

  # Resolved at runtime, as in `OvcsVehicle.FirmwareValidator`: this
  # library depends on neither, and the firmwares bring both.
  @vintage_net_parts [:VintageNet]
  @nerves_time_parts [:NervesTime]

  @doc false
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: opts[:name])

  @doc """
  Restart `ntpd` if the network is up and the clock is not synchronized.
  Returns `:restarted` or `:ok`.
  """
  @spec check(keyword()) :: :restarted | :ok
  def check(opts \\ []) do
    if call(opts, :connected?) and not call(opts, :synchronized?) do
      Logger.info("#{__MODULE__}: network up and clock not synchronized; restarting ntpd")
      call(opts, :restart)
      :restarted
    else
      :ok
    end
  end

  @impl GenServer
  def init(opts) do
    call(opts, :subscribe)
    {:ok, %{opts: opts, timer: schedule(opts)}}
  end

  @impl GenServer
  def handle_info({VintageNet, ["connection"], _old, :internet, _meta}, state),
    do: {:noreply, check_and_reschedule(state)}

  def handle_info({VintageNet, ["connection"], _old, _new, _meta}, state), do: {:noreply, state}

  def handle_info(:check, state), do: {:noreply, check_and_reschedule(state)}

  defp check_and_reschedule(%{opts: opts, timer: timer} = state) do
    Process.cancel_timer(timer)
    check(opts)
    %{state | timer: schedule(opts)}
  end

  defp schedule(opts),
    do: Process.send_after(self(), :check, Keyword.get(opts, :interval_ms, @interval_ms))

  defp call(opts, name), do: Keyword.get_lazy(opts, name, fn -> default(name) end).()

  defp default(:connected?), do: fn -> vintage_net().get(["connection"]) == :internet end
  defp default(:synchronized?), do: fn -> nerves_time().synchronized?() end
  defp default(:restart), do: fn -> nerves_time().restart_ntpd() end
  defp default(:subscribe), do: fn -> vintage_net().subscribe(["connection"]) end

  defp vintage_net, do: Module.concat(@vintage_net_parts)
  defp nerves_time, do: Module.concat(@nerves_time_parts)
end
