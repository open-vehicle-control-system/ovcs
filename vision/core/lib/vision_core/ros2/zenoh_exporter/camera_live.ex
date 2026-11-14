defmodule VisionCore.Ros2.ZenohExporter.CameraLive do
  @moduledoc """
  Plots what the cameras of their own apply: each camera's exposure and
  gain (`VisionCore.Ros2.ZenohExporter.Camera.live_messages/2`), five times a
  second, as `VisionCore.Ros2.ZenohExporter.Diagnostics` plots the stereo
  unit's.

  `VisionCore.Ros2.ZenohExporter` starts it as a helper under its own
  supervisor for the cameras it publishes whose driver reports what it
  applied (`c:VisionCore.Camera.live/1`). It asks the drivers from its
  own process, so a camera that is slow to answer never holds up the
  exporter; one that is down reported nothing.

  ## Options

    * `:cameras` (required) — each camera's topic root
      (`VisionCore.Ros2.ZenohExporter.Camera.topic_root/2`), driver and the
      name its driver registers it under.
    * `:publish` (`&VisionCore.Ros2.Topics.publish/4`) — sends one
      message, as `VisionCore.Ros2.ZenohExporter`'s does.
    * `:name` (this module) — the name it registers under.
  """

  use GenServer

  alias VisionCore.Ros2.ZenohExporter.Camera
  alias VisionCore.Ros2.Topics

  @plot_period_ms 200

  @doc "Starts plotting the cameras; see the module doc."
  def start_link(opts),
    do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  @impl GenServer
  def init(opts) do
    Process.send_after(self(), :plot, @plot_period_ms)

    {:ok,
     %{
       cameras: Keyword.fetch!(opts, :cameras),
       publish: Keyword.get(opts, :publish, &Topics.publish/4)
     }}
  end

  @impl GenServer
  def handle_info(:plot, state) do
    Process.send_after(self(), :plot, @plot_period_ms)

    for {topic_root, driver, server} <- state.cameras,
        {topic, module, message} <- Camera.live_messages(topic_root, live(driver, server)),
        do: state.publish.(topic, module, message, [])

    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  # A camera that is not running reported nothing.
  defp live(driver, server) do
    driver.live(server)
  catch
    :exit, _reason -> nil
  end
end
