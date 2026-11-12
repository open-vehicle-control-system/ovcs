defmodule VisionCore.Detection.Live do
  @moduledoc """
  The latest detections of a `VisionCore.Detection.Pipeline`, for the
  dashboard: each object's label, score, distance in metres, `nil` for
  one without, and outline on its source's image as it is captured, the
  left camera's or, on a camera source, the camera's, which that
  camera's preview shows. Each pipeline has its own, registered as
  `VisionCore.Pipelines.server(VisionCore.Detection.Live, name)`.

  A subscriber (`subscribe/1`) receives `{:vision_detections,
  detections}` after a detection result, at most `:max_hz` times a
  second, an empty list included, so the boxes of the last result go
  away; `VisionCore.Live` holds the latest meanwhile. Each detection is `%{label:, score:, distance_m:, outline:}`, the
  outline a closed list of `[x, y]` vertices as fractions of the image's
  width and height: the `:outline` the detection pipeline mapped to the
  captured image, which the ROS 2 overlay draws too.

  Started by `VisionCore.Detection.Supervisor` after the pipeline.

  ## Options

    * `:name` (`:detection`) — the pipeline whose results it hands on.
    * `:max_hz` (`10`) — results a second sent to each subscriber, an
      integer from 1 on.
  """
  alias VisionCore.Camera.Frame
  alias VisionCore.{Detection, Pipelines}
  alias VisionCore.Detection.Pipeline
  alias VisionCore.Stereo.Pair

  @default_max_hz 10

  @doc false
  def child_spec(opts), do: %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}}

  def start_link(opts) do
    name = Detection.pipeline_name(opts)

    VisionCore.Live.start_link(
      name: Pipelines.server(__MODULE__, name),
      key: {:detections, Pipelines.server(Pipeline, name)},
      tag: :vision_detections,
      describe: &describe/1,
      max_hz: Keyword.get(opts, :max_hz, @default_max_hz)
    )
  end

  @doc """
  Sends the calling process every later result of the pipeline `name`,
  until it exits.
  """
  @spec subscribe(atom()) :: :ok
  def subscribe(name \\ :detection),
    do: VisionCore.Live.subscribe(Pipelines.server(__MODULE__, name))

  @doc "The most results a subscriber of the pipeline `name` receives a second, its `:max_hz`."
  @spec max_hz(atom()) :: pos_integer()
  def max_hz(name \\ :detection), do: VisionCore.Live.max_hz(Pipelines.server(__MODULE__, name))

  defp describe({:detections, source, positioned}), do: {:ok, describe(positioned, image(source))}

  defp describe({:detections, source, positioned, _name}),
    do: {:ok, describe(positioned, image(source))}

  defp describe(_message), do: :ignore

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
