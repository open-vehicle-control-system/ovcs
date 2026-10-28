defmodule VisionCore.Stereo.Sources do
  @moduledoc """
  Keeps a process registered as a listener on the stereo unit's camera
  drivers and pipeline, for `VisionCore.Status` and
  `VisionCore.Preview`.

  Those sources run under `VisionCore.Stereo.Supervisor`, whose
  own restarts do not reach processes outside it, and a restarted source
  comes back with no listeners. So each source is monitored and, once it
  stops, registered on again when its supervisor has restarted it. A
  source that is not running yet is retried every half second.
  """

  alias VisionCore.Stereo.Pipeline

  @retry_ms 500

  @typedoc "A source's module, which exposes `register_listener/2`, and its server."
  @type source :: {module(), GenServer.server()}
  @type monitors :: %{reference() => source()}

  @doc """
  The stereo unit's sources in `config`: its pipeline, then its
  left and right camera drivers. `[]` without a `:stereo`
  component.
  """
  @spec from_config(VisionCore.Config.t()) :: [source()]
  def from_config(%VisionCore.Config{components: components}) do
    case Enum.find_value(components, &stereo_options/1) do
      nil ->
        []

      options ->
        driver = Keyword.fetch!(options, :driver)
        Code.ensure_loaded(driver)

        [
          {Pipeline, Pipeline},
          {driver, driver.name_for("left")},
          {driver, driver.name_for("right")}
        ]
    end
  end

  defp stereo_options({:stereo, options}), do: options
  defp stereo_options(_component), do: nil

  @doc """
  Registers the caller on each running source and monitors it. A source
  not running is retried with a `{:register_source, source}` message to
  the caller, to pass to `retry/2`.
  """
  @spec register([source()]) :: monitors()
  def register(sources), do: Enum.reduce(sources, %{}, &register_source/2)

  @doc "Handles a `{:register_source, source}` message."
  @spec retry(source(), monitors()) :: monitors()
  def retry(source, monitors), do: register_source(source, monitors)

  @doc """
  Handles a `:DOWN` message: registers again on the source it
  monitored. `:error` when `monitor_reference` is not a source's.
  """
  @spec down(reference(), monitors()) :: {:ok, monitors()} | :error
  def down(monitor_reference, monitors) do
    case Map.pop(monitors, monitor_reference) do
      {nil, _monitors} -> :error
      {source, monitors} -> {:ok, register_source(source, monitors)}
    end
  end

  defp register_source({module, server} = source, monitors) do
    case GenServer.whereis(server) do
      nil ->
        Process.send_after(self(), {:register_source, source}, @retry_ms)
        monitors

      pid ->
        module.register_listener(server, self())
        Map.put(monitors, Process.monitor(pid), source)
    end
  end
end
