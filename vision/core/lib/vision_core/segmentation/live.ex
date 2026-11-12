defmodule VisionCore.Segmentation.Live do
  @moduledoc """
  The latest label image of a `VisionCore.Segmentation.Pipeline`, for
  the dashboard, which draws it over its camera's preview. Each pipeline
  has its own, registered as
  `VisionCore.Detection.server(VisionCore.Segmentation.Live, name)`.

  A subscriber (`subscribe/1`) receives `{:vision_segmentation,
  segmentation}` after a result, at most `:max_hz` times a second. A
  result that comes sooner is held and sent once the interval has
  passed, unless a newer one replaces it, so the latest always arrives.
  `segmentation` is `%{frame: {width, height}, band: {x, y, w, h},
  width:, height:, data:}`: the size of the camera's image, the band of
  it the label image covers, in its pixels, and the label image,
  `width * height` class ids, one byte each, row by row. `classes/1`
  names them.

  Started by `VisionCore.Segmentation.Supervisor` after the pipeline.

  ## Options

    * `:name` (required) — the pipeline whose results it hands on.
    * `:max_hz` (`5`) — results a second sent to each subscriber, an
      integer from 1 on.
    * `:labels` (the Cityscapes classes) and `:road_classes`
      (`["road"]`) — the pipeline's, which `classes/1` answers.
  """
  use GenServer

  alias VisionCore.Detection
  alias VisionCore.Outputs
  alias VisionCore.Segmentation.Pipeline

  @default_max_hz 5

  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: Detection.server(__MODULE__, name))
  end

  @doc "Sends the calling process every later result of the pipeline `name`, until it exits."
  @spec subscribe(atom()) :: :ok
  def subscribe(name),
    do: GenServer.call(Detection.server(__MODULE__, name), {:subscribe, self()})

  @doc "The most results a subscriber of the pipeline `name` receives a second, its `:max_hz`."
  @spec max_hz(atom()) :: pos_integer()
  def max_hz(name), do: GenServer.call(Detection.server(__MODULE__, name), :max_hz)

  @doc """
  The names of the pipeline `name`'s classes, indexed by class id, and
  those of them that are road.
  """
  @spec classes(atom()) :: %{labels: [String.t()], road_classes: [String.t()]}
  def classes(name), do: GenServer.call(Detection.server(__MODULE__, name), :classes)

  @impl GenServer
  def init(opts) do
    name = Keyword.fetch!(opts, :name)
    :ok = Outputs.subscribe({:segmentation, Detection.server(Pipeline, name)})
    max_hz = VisionCore.Options.integer!(opts, :max_hz, @default_max_hz, 1)

    {:ok,
     %{
       max_hz: max_hz,
       interval_ms: div(1_000, max_hz),
       classes: %{
         labels: Keyword.get(opts, :labels, VisionCore.Segmentation.labels()),
         road_classes: Keyword.get(opts, :road_classes, ["road"])
       },
       subscribers: %{},
       sent_at_ms: nil,
       held: nil
     }}
  end

  @impl GenServer
  def handle_call(:max_hz, _from, state), do: {:reply, state.max_hz, state}
  def handle_call(:classes, _from, state), do: {:reply, state.classes, state}

  def handle_call({:subscribe, pid}, _from, state) do
    subscribers = Map.put_new_lazy(state.subscribers, pid, fn -> Process.monitor(pid) end)
    {:reply, :ok, %{state | subscribers: subscribers}}
  end

  @impl GenServer
  def handle_cast(
        {:segmentation, _name, _frame, _labels, _clouds},
        %{subscribers: subscribers} = state
      )
      when map_size(subscribers) == 0,
      do: {:noreply, state}

  def handle_cast({:segmentation, _name, frame, labels, _clouds}, state) do
    segmentation = Map.put(labels, :frame, {frame.width, frame.height})
    now_ms = System.monotonic_time(:millisecond)

    cond do
      due?(state, now_ms) ->
        {:noreply, send_segmentation(segmentation, now_ms, state)}

      is_nil(state.held) ->
        Process.send_after(self(), :send_held, state.sent_at_ms + state.interval_ms - now_ms)
        {:noreply, %{state | held: segmentation}}

      true ->
        {:noreply, %{state | held: segmentation}}
    end
  end

  def handle_cast(_message, state), do: {:noreply, state}

  @impl GenServer
  def handle_info(:send_held, %{held: nil} = state), do: {:noreply, state}

  def handle_info(:send_held, state),
    do: {:noreply, send_segmentation(state.held, System.monotonic_time(:millisecond), state)}

  def handle_info({:DOWN, _reference, :process, pid, _reason}, state),
    do: {:noreply, %{state | subscribers: Map.delete(state.subscribers, pid)}}

  def handle_info(_message, state), do: {:noreply, state}

  defp send_segmentation(segmentation, now_ms, state) do
    for pid <- Map.keys(state.subscribers), do: send(pid, {:vision_segmentation, segmentation})
    %{state | sent_at_ms: now_ms, held: nil}
  end

  defp due?(%{sent_at_ms: nil}, _now_ms), do: true
  defp due?(state, now_ms), do: now_ms - state.sent_at_ms >= state.interval_ms
end
