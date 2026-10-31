defmodule VisionCore.Detection.Live do
  @moduledoc """
  The latest detections of `VisionCore.Detection.Pipeline`, for the
  dashboard: each object's label, score, distance in metres and outline
  on the left camera's image as it is captured, which the left preview
  shows.

  A subscriber (`subscribe/0`) receives `{:vision_detections,
  detections}` after a detection result, at most `:max_hz` times a
  second, an empty list included, so the boxes of the last result go
  away. A result that comes sooner is held and sent once the interval
  has passed, unless a newer one replaces it, so the latest always
  arrives. Each detection is `%{label:, score:, distance_m:, outline:}`, the
  outline a closed list of `[x, y]` vertices as fractions of the image's
  width and height. The box is computed on the rectified image, so it is
  mapped back to the captured one, like the ROS 2 overlay of
  `VisionCore.Ros2.Publishers.Detections`, and its edges are subdivided
  so they can follow the lens distortion. The map that does it is
  computed once per calibration, in a task: until it is ready, the
  outlines are only scaled to the captured image.

  Started by `VisionCore.Detection.Supervisor` after the pipeline.

  ## Options

    * `:max_hz` (`10`) — results a second sent to each subscriber.
    * `:outline_segments` (`4`) — pieces each box edge is cut into.
  """
  use GenServer

  alias VisionCore.Detection.{Fusion, Pipeline}
  alias VisionCore.Stereo.Pair

  @default_max_hz 10
  @default_outline_segments 4

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Sends the calling process every later result, until it exits."
  @spec subscribe() :: :ok
  def subscribe, do: GenServer.call(__MODULE__, {:subscribe, self()})

  @doc "How many processes are subscribed."
  @spec subscriber_count() :: non_neg_integer()
  def subscriber_count, do: GenServer.call(__MODULE__, :subscriber_count)

  @impl GenServer
  def init(opts) do
    Pipeline.register_listener(Pipeline, self())

    {:ok,
     %{
       interval_ms: div(1_000, Keyword.get(opts, :max_hz, @default_max_hz)),
       outline_segments: Keyword.get(opts, :outline_segments, @default_outline_segments),
       subscribers: %{},
       sent_at_ms: nil,
       held: nil,
       map: nil,
       mapping: nil
     }}
  end

  @impl GenServer
  def handle_call({:subscribe, pid}, _from, state),
    do: {:reply, :ok, put_in(state.subscribers[pid], Process.monitor(pid))}

  def handle_call(:subscriber_count, _from, state),
    do: {:reply, map_size(state.subscribers), state}

  @impl GenServer
  def handle_cast({:detections, %Pair{} = pair, positioned}, state) do
    now_ms = System.monotonic_time(:millisecond)

    cond do
      map_size(state.subscribers) == 0 ->
        {:noreply, state}

      due?(state, now_ms) ->
        {:noreply, send_result({pair, positioned}, now_ms, state)}

      true ->
        if is_nil(state.held),
          do:
            Process.send_after(self(), :send_held, state.sent_at_ms + state.interval_ms - now_ms)

        {:noreply, %{state | held: {pair, positioned}}}
    end
  end

  def handle_cast(_message, state), do: {:noreply, state}

  @impl GenServer
  def handle_info(:send_held, %{held: nil} = state), do: {:noreply, state}

  def handle_info(:send_held, state),
    do: {:noreply, send_result(state.held, System.monotonic_time(:millisecond), state)}

  def handle_info({reference, map_binary}, %{mapping: {reference, calibration}} = state) do
    Process.demonitor(reference, [:flush])
    {:noreply, %{state | map: {calibration, map_binary}, mapping: nil}}
  end

  def handle_info(
        {:DOWN, reference, :process, _pid, _reason},
        %{mapping: {reference, _}} = state
      ),
      do: {:noreply, %{state | mapping: nil}}

  def handle_info({:DOWN, _reference, :process, pid, _reason}, state),
    do: {:noreply, %{state | subscribers: Map.delete(state.subscribers, pid)}}

  def handle_info(_message, state), do: {:noreply, state}

  defp send_result({pair, positioned}, now_ms, state) do
    {map_binary, state} = map_for(pair, state)
    detections = Enum.map(positioned, &describe(&1, pair, map_binary, state))
    for pid <- Map.keys(state.subscribers), do: send(pid, {:vision_detections, detections})
    %{state | sent_at_ms: now_ms, held: nil}
  end

  # The map of the pair's calibration, or nil while a task computes it.
  defp map_for(%Pair{geometry: %{left_calibration: calibration}}, state)
       when not is_nil(calibration) do
    case state do
      %{map: {^calibration, map_binary}} ->
        {map_binary, state}

      %{mapping: {_reference, ^calibration}} ->
        {nil, state}

      _other ->
        task = Task.async(fn -> Fusion.rectification_map(calibration) end)
        {nil, %{state | mapping: {task.ref, calibration}}}
    end
  end

  defp map_for(_pair, state), do: {nil, state}

  defp due?(%{sent_at_ms: nil}, _now_ms), do: true
  defp due?(state, now_ms), do: now_ms - state.sent_at_ms >= state.interval_ms

  defp describe(detection, %Pair{left_frame: frame} = pair, map_binary, state) do
    outline =
      detection.box
      |> Fusion.perimeter(state.outline_segments)
      |> Enum.map(&Fusion.raw_point(&1, map_binary, pair))
      |> Enum.reject(&is_nil/1)
      |> Enum.map(fn {x, y} -> [x / frame.width, y / frame.height] end)

    %{label: detection.label, score: detection.score, distance_m: detection.z, outline: outline}
  end
end
