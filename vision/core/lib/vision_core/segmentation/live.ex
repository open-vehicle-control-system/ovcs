defmodule VisionCore.Segmentation.Live do
  @moduledoc """
  The latest label image of a `VisionCore.Segmentation.Pipeline`, for
  the dashboard, which draws it over its camera's preview. Each pipeline
  has its own, registered as
  `VisionCore.Pipelines.server(VisionCore.Segmentation.Live, name)`.

  A subscriber (`subscribe/1`) receives `{:vision_segmentation,
  segmentation}` after a result, at most `:max_hz` times a second;
  `VisionCore.Live` holds the latest meanwhile.

  `segmentation` is `%{frame: {width, height}, band: {x, y, w, h},
  width:, height:, data:}`: the size of the camera's image, the band of
  it the label image covers, in its pixels, and the label image,
  `width * height` class ids, one byte each, row by row.
  `VisionCore.Segmentation.Supervisor.classes/2` names them.

  Started by `VisionCore.Segmentation.Supervisor` after the pipeline.

  ## Options

    * `:name` (required) — the pipeline whose results it hands on.
    * `:max_hz` (`5`) — results a second sent to each subscriber, an
      integer from 1 on.
  """
  alias VisionCore.Pipelines
  alias VisionCore.Segmentation.Pipeline

  @default_max_hz 5

  @doc false
  def child_spec(opts), do: %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}}

  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)

    VisionCore.Live.start_link(
      name: Pipelines.server(__MODULE__, name),
      key: {:segmentation, Pipelines.server(Pipeline, name)},
      tag: :vision_segmentation,
      describe: &describe/1,
      max_hz: Keyword.get(opts, :max_hz, @default_max_hz)
    )
  end

  @doc "Sends the calling process every later result of the pipeline `name`, until it exits."
  @spec subscribe(atom()) :: :ok
  def subscribe(name), do: VisionCore.Live.subscribe(Pipelines.server(__MODULE__, name))

  @doc "The most results a subscriber of the pipeline `name` receives a second, its `:max_hz`."
  @spec max_hz(atom()) :: pos_integer()
  def max_hz(name), do: VisionCore.Live.max_hz(Pipelines.server(__MODULE__, name))

  defp describe({:segmentation, _name, frame, labels, _clouds}),
    do: {:ok, Map.put(labels, :frame, {frame.width, frame.height})}

  defp describe(_message), do: :ignore
end
