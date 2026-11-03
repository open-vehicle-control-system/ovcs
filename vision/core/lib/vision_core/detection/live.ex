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
  width and height: the `:outline` the detection pipeline mapped to the
  captured image, which the ROS 2 overlay draws too.

  Started by `VisionCore.Detection.Supervisor` after the pipeline.

  ## Options

    * `:max_hz` (`10`) — results a second sent to each subscriber.
  """
  use GenServer

  alias VisionCore.Detection.Pipeline
  alias VisionCore.Outputs
  alias VisionCore.Stereo.Pair

  @default_max_hz 10

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Sends the calling process every later result, until it exits."
  @spec subscribe() :: :ok
  def subscribe, do: GenServer.call(__MODULE__, {:subscribe, self()})

  @doc "The most results a subscriber receives a second, its `:max_hz`."
  @spec max_hz() :: pos_integer()
  def max_hz, do: GenServer.call(__MODULE__, :max_hz)

  @impl GenServer
  def init(opts) do
    :ok = Outputs.subscribe({:detections, Pipeline})
    max_hz = Keyword.get(opts, :max_hz, @default_max_hz)

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
  def handle_cast({:detections, _pair, _positioned}, %{subscribers: subscribers} = state)
      when map_size(subscribers) == 0,
      do: {:noreply, state}

  def handle_cast({:detections, %Pair{} = pair, positioned}, state) do
    detections = describe(positioned, pair)
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

  def handle_cast(_message, state), do: {:noreply, state}

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

  defp describe(positioned, %Pair{left_frame: frame}) do
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
