defmodule OvcsVehicle.CpuGovernor do
  @moduledoc """
  Sets every CPU's frequency governor to `performance`.

  Under `schedutil`, Linux's default governor, interrupt latency at low
  clock speeds is long enough for an SPI-attached UART such as the
  SC16IS752 to overrun its 64-byte FIFO at 460800 baud, dropping incoming
  bytes. On a vehicle, control latency matters more than power draw. The
  OVCS systems also default to `performance`; this keeps it so on a
  system image that does not.

  Wired in as a `Task` child like `OvcsVehicle.FirmwareValidator`, and
  only on target:

      children =
        if Nerves.Runtime.mix_target() == :host,
          do: children,
          else: [OvcsVehicle.CpuGovernor | children]
  """

  require Logger

  @governor "performance"
  @default_glob "/sys/devices/system/cpu/cpu*/cpufreq/scaling_governor"

  @doc "Child spec that sets the governor once, then exits."
  def child_spec(opts \\ []) do
    %{
      id: __MODULE__,
      start: {Task, :start_link, [fn -> apply_governor(opts) end]},
      restart: :transient
    }
  end

  @doc """
  Write `performance` to each `scaling_governor` file matching `:glob`.

  Never raises: a board without cpufreq keeps its current governor.
  """
  def apply_governor(opts \\ []) do
    paths = opts |> Keyword.get(:glob, @default_glob) |> Path.wildcard()

    results = Enum.map(paths, &{&1, File.write(&1, @governor)})

    case Enum.reject(results, fn {_, result} -> result == :ok end) do
      [] -> Logger.info("#{__MODULE__}: #{length(paths)} CPU(s) set to #{@governor}")
      failed -> Logger.error("#{__MODULE__}: could not set #{@governor}: #{inspect(failed)}")
    end

    :ok
  end
end
