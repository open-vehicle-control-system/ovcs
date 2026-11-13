defmodule VisionCore.Detection.CameraPipeline do
  @moduledoc """
  A `VisionCore.Detection.Pipeline` on a camera of its own: what
  `VisionCore.CameraPipeline`, which runs it, sends the backend of a
  frame, a tensor of it, and what the boxes that come back become,
  placed with the depth of the stereo pair matched with the frame
  (`VisionCore.Detection.CameraSource`). See
  `VisionCore.Detection.Pipeline` for what it publishes and its options.
  """
  @behaviour VisionCore.CameraPipeline

  require Logger

  alias VisionCore.Camera.Frame
  alias VisionCore.Detection.{CameraSource, Pipeline}

  @wording %{
    calibration: "its detections have no distance nor bearing",
    pose: "its detections have no distance",
    unreadable: "its detections have no distance",
    unmatched: "its detections have no distance",
    lens: "place detections"
  }

  @doc "Starts the pipeline; `start_options` are `GenServer.start_link/3`'s."
  @spec start_link(keyword(), keyword()) :: GenServer.on_start()
  def start_link(opts, start_options),
    do: VisionCore.CameraPipeline.start_link(__MODULE__, opts, start_options)

  @impl VisionCore.CameraPipeline
  def init(opts) do
    opts |> Pipeline.settings() |> Map.put(:undecodable_logged, false)
  end

  @impl VisionCore.CameraPipeline
  def every_n(settings), do: settings.detect_every_n

  @impl VisionCore.CameraPipeline
  def depth_wording(settings), do: {"detection pipeline #{settings.name}", @wording}

  @impl VisionCore.CameraPipeline
  defdelegate groups(settings), to: Pipeline

  @impl VisionCore.CameraPipeline
  defdelegate output_key(settings), to: Pipeline

  @impl VisionCore.CameraPipeline
  def accept(_frame, settings), do: {:ok, settings}

  @impl VisionCore.CameraPipeline
  def prepare(frame, settings) do
    case Frame.to_tensor(frame) do
      {:ok, image} -> {:submit, image, nil, %{settings | undecodable_logged: false}}
      {:error, reason} -> {:skip, note_undecodable(settings, reason)}
    end
  end

  defp note_undecodable(%{undecodable_logged: true} = settings, _reason), do: settings

  defp note_undecodable(%{source: {:camera, camera, _output}} = settings, reason) do
    Logger.warning(
      "detection pipeline #{settings.name}: cannot detect on the camera #{camera}'s " <>
        "images, which do not decode: #{inspect(reason)}"
    )

    %{settings | undecodable_logged: true}
  end

  @impl VisionCore.CameraPipeline
  def submit(image, sequence, settings),
    do: settings.backend.detect(settings.backend_server, sequence, image)

  @impl VisionCore.CameraPipeline
  def reply_tag, do: :inference_detections

  @impl VisionCore.CameraPipeline
  def result(detections, _kept, settings) do
    labelled = detections |> Pipeline.select(settings) |> Enum.map(&labelled(&1, settings))
    {labelled, labelled != []}
  end

  defp labelled(detection, settings) do
    %{
      box: detection,
      class_id: detection.class_id,
      label: Pipeline.label(detection, settings),
      score: detection.score
    }
  end

  @impl VisionCore.CameraPipeline
  def finish(frame, labelled, pair, camera, settings) do
    {placed, camera} =
      CameraSource.place(
        camera,
        labelled,
        frame,
        pair,
        settings.depth_sample_fraction,
        settings.reprojection_stride
      )

    detections =
      Enum.map(placed, fn detection ->
        Map.merge(detection, %{
          outline: CameraSource.outline(detection.box),
          caption: Pipeline.caption(detection)
        })
      end)

    {Pipeline.message(settings, frame, detections), camera}
  end
end
