defmodule VisionCore.Detection.Live do
  @moduledoc """
  The latest detections of a `VisionCore.Detection.Pipeline`, for the
  dashboard: each object's label, score, distance in metres, `nil` for
  one without, and outline on its source's image as it is captured, the
  left camera's or, on a camera source, the camera's, which that
  camera's preview shows. Each pipeline has its own, registered as
  `VisionCore.Detection.server(VisionCore.Detection.Live, name)`.

  A subscriber (`subscribe/1`) receives `{:vision_detections,
  detections}` after a detection result, at most `:max_hz` times a
  second, an empty list included, so the boxes of the last result go
  away. A result that comes sooner is held and sent once the interval
  has passed, unless a newer one replaces it, so the latest always
  arrives. Each detection is `%{label:, score:, distance_m:, outline:}`, the
  outline a closed list of `[x, y]` vertices as fractions of the image's
  width and height: the `:outline` the detection pipeline mapped to the
  captured image, which the ROS 2 overlay draws too.

  Started by `VisionCore.Detection.Supervisor` after the pipeline.

  ## Options

    * `:name` (`:detection`) — the pipeline whose results it hands on.
    * `:max_hz` (`10`) — results a second sent to each subscriber, an
      integer from 1 on.
  """
  use GenServer

  alias VisionCore.Camera.Frame
  alias VisionCore.Detection
  alias VisionCore.Detection.Pipeline
  alias VisionCore.Outputs
  alias VisionCore.Stereo.Pair

  @default_max_hz 10

  def start_link(opts) do
    name = Detection.pipeline_name(opts)
    GenServer.start_link(__MODULE__, opts, name: Detection.server(__MODULE__, name))
  end

  @doc """
  Sends the calling process every later result of the pipeline `name`,
  until it exits.
  """
  @spec subscribe(atom()) :: :ok
  def subscribe(name \\ :detection),
    do: GenServer.call(Detection.server(__MODULE__, name), {:subscribe, self()})

  @doc "The most results a subscriber of the pipeline `name` receives a second, its `:max_hz`."
  @spec max_hz(atom()) :: pos_integer()
  def max_hz(name \\ :detection), do: GenServer.call(Detection.server(__MODULE__, name), :max_hz)

  @impl GenServer
  def init(opts) do
    :ok =
      Outputs.subscribe({:detections, Detection.server(Pipeline, Detection.pipeline_name(opts))})

    max_hz = VisionCore.Options.integer!(opts, :max_hz, @default_max_hz, 1)

    {:ok,
     %{
       max_hz: max_hz,
       interval_ms: div(1_000, max_hz),
       subscribers: %{},
       sent_at_ms: nil,
       held: nil
     }}
  end

  @impl GenServer
  def handle_call(:max_hz, _from, state), do: {:reply, state.max_hz, state}

  def handle_call({:subscribe, pid}, _from, state) do
    subscribers = Map.put_new_lazy(state.subscribers, pid, fn -> Process.monitor(pid) end)
    {:reply, :ok, %{state | subscribers: subscribers}}
  end

  @impl GenServer
  def handle_cast({:detections, pair, positioned}, state),
    do: hand_on(pair, positioned, state)

  def handle_cast({:detections, pair, positioned, _name}, state),
    do: hand_on(pair, positioned, state)

  def handle_cast(_message, state), do: {:noreply, state}

  defp hand_on(_pair, _positioned, %{subscribers: subscribers} = state)
       when map_size(subscribers) == 0,
       do: {:noreply, state}

  defp hand_on(source, positioned, state) do
    detections = describe(positioned, image(source))
    now_ms = System.monotonic_time(:millisecond)

    cond do
      due?(state, now_ms) ->
        {:noreply, send_detections(detections, now_ms, state)}

      is_nil(state.held) ->
        Process.send_after(self(), :send_held, state.sent_at_ms + state.interval_ms - now_ms)
        {:noreply, %{state | held: detections}}

      true ->
        {:noreply, %{state | held: detections}}
    end
  end

  @impl GenServer
  def handle_info(:send_held, %{held: nil} = state), do: {:noreply, state}

  def handle_info(:send_held, state),
    do: {:noreply, send_detections(state.held, System.monotonic_time(:millisecond), state)}

  def handle_info({:DOWN, _reference, :process, pid, _reason}, state),
    do: {:noreply, %{state | subscribers: Map.delete(state.subscribers, pid)}}

  def handle_info(_message, state), do: {:noreply, state}

  defp send_detections(detections, now_ms, state) do
    for pid <- Map.keys(state.subscribers), do: send(pid, {:vision_detections, detections})
    %{state | sent_at_ms: now_ms, held: nil}
  end

  defp due?(%{sent_at_ms: nil}, _now_ms), do: true
  defp due?(state, now_ms), do: now_ms - state.sent_at_ms >= state.interval_ms

  defp image(%Pair{left_frame: frame}), do: frame
  defp image(%Frame{} = frame), do: frame

  defp describe(positioned, frame) do
    Enum.map(positioned, fn detection ->
      %{
        label: detection.label,
        score: detection.score,
        distance_m: detection.z,
        outline: Enum.map(detection.outline, fn {x, y} -> [x / frame.width, y / frame.height] end)
      }
    end)
  end
end
