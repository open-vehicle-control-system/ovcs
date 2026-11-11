defmodule OvcsVehicle.CpuGovernor do
  @moduledoc """
  Sets every CPU's frequency governor to `performance`.

  Under `schedutil`, Linux's default governor, interrupt latency at low
  clock speeds is long enough for an SPI-attached UART such as the
  SC16IS752 to overrun its 64-byte FIFO at 460800 baud, dropping incoming
  bytes. On a vehicle, control latency matters more than power draw. The
  OVCS systems also default to `performance`; this keeps it so on a
  system image that does not.

  `:glob` and `:devices` point it at other frequency governors, such as a
  devfreq GPU's, and name them in its log line. A devfreq device that
  offers no `performance` governor, such as the Adreno GPU of the Arduino
  VENTUNO Q, is pinned instead: its `min_freq` is set to its `max_freq`.
  `:await` waits up to that many milliseconds for a device whose driver
  probes after the VM starts, as a GPU's does.

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
    glob = Keyword.get(opts, :glob, @default_glob)
    paths = await_paths(glob, System.monotonic_time(:millisecond) + Keyword.get(opts, :await, 0))
    devices = Keyword.get(opts, :devices, "CPU")

    results =
      Enum.map(paths, fn path ->
        case File.write(path, @governor) do
          :ok -> {path, :governor}
          error -> {path, pin_maximum(path, error)}
        end
      end)

    count = fn outcome -> Enum.count(results, &(elem(&1, 1) == outcome)) end

    case Enum.reject(results, fn {_, outcome} -> outcome in [:governor, :pinned] end) do
      [] ->
        Logger.info("#{__MODULE__}: #{count.(:governor)} #{devices}(s) set to #{@governor}")

        if count.(:pinned) > 0,
          do:
            Logger.info(
              "#{__MODULE__}: #{count.(:pinned)} #{devices}(s) pinned at their maximum frequency"
            )

      failed ->
        Logger.error("#{__MODULE__}: could not set #{@governor}: #{inspect(failed)}")
    end

    :ok
  end

  defp await_paths(glob, deadline) do
    case Path.wildcard(glob) do
      [] ->
        if System.monotonic_time(:millisecond) < deadline do
          Process.sleep(100)
          await_paths(glob, deadline)
        else
          []
        end

      paths ->
        paths
    end
  end

  # A devfreq device beside `governor_path` runs at its maximum once its minimum is raised to it.
  defp pin_maximum(governor_path, error) do
    directory = Path.dirname(governor_path)

    with {:ok, maximum} <- File.read(Path.join(directory, "max_freq")),
         :ok <- File.write(Path.join(directory, "min_freq"), String.trim(maximum)) do
      :pinned
    else
      _ -> error
    end
  end
end
