defmodule VisionCore.Detection.Backend.Hailo do
  @moduledoc """
  Detection on the Hailo-8: the lane of `VisionCore.Hailo` named after
  the pipeline, the one Port that runs the unit's networks on the
  accelerator. A
  detection unit with this backend starts no backend of its own: the
  vision core starts `VisionCore.Hailo` from the unit's options
  (`VisionCore.Components.hailo_children/1`), and the unit restarts
  with it (`VisionCore.Inference.Watch`).

  `detect/3` is asynchronous and drops the frame while another is at the
  accelerator, answering `{:error, :busy}`: queueing frames would only
  add latency to a measurement whose value is being current. The caller
  receives `{:inference_detections, sequence, detections}`, each
  detection

      %{class_id: 0..79, score: 0.0..1.0, x0:, y0:, x1:, y1:}

  in the submitted image's pixels, `nil` when the Port could not answer.

  ## Options

  The unit's, which `VisionCore.Hailo` takes as the pipeline's network:

    * `:hef_path` — the model (required).
    * `:score_threshold` (`0.4`) — the lowest score `hailo` reports.

  and the Port's: `:executable`, `:working_directory`, `:library_path`,
  `:infer_timeout_ms` and `:reopen_delays_ms` (`VisionCore.Hailo`).
  """
  @behaviour VisionCore.Detection.Backend

  alias VisionCore.Detection.Pipeline
  alias VisionCore.Inference.PortBackend
  alias VisionCore.Stereo.Parameters

  @explanation "Runs object detection on the Hailo-8 accelerator. It finds people, vehicles, " <>
                 "animals and everyday objects, the 80 COCO classes, each as a box with a score. " <>
                 "The model and score_threshold, the lowest score the accelerator reports, are " <>
                 "fixed in the build. When the accelerator is not ready, inference waits and " <>
                 "starts again, and the depth carries on without it: Hailo in the top bar shows " <>
                 "its state."

  @doc "The process every unit with this backend shares: `VisionCore.Hailo`."
  @spec shared_process() :: module()
  def shared_process, do: VisionCore.Hailo

  @doc "The server the unit `name` submits to: its pipeline's lane of `VisionCore.Hailo`."
  @spec shared_server(atom()) :: {module(), atom()}
  def shared_server(name), do: {VisionCore.Hailo, name}

  @doc """
  Submit a `u8` `{height, width}` (or `{height, width, 3}` RGB) tensor
  for detection. Returns `:ok` when the frame was handed to the
  accelerator, `{:error, :busy}` when one is already in flight, and
  `{:error, :unavailable}` without a Port.
  """
  @impl VisionCore.Detection.Backend
  def detect({process, lane}, sequence, image),
    do: PortBackend.submit(process, lane, sequence, image)

  @doc "Whether the accelerator is loaded and answering, an inference in flight or not."
  @impl VisionCore.Detection.Backend
  def available?({process, _lane}), do: PortBackend.available?(process)

  @doc """
  The sum and the count of the detection times `hailo` reported since
  the last call, in microseconds, which this starts again; `nil` until
  it has reported one since the Port last opened, and when it is gone.
  """
  @impl VisionCore.Detection.Backend
  def inference_times({process, lane}),
    do: PortBackend.inference_times(process, lane)

  @impl VisionCore.Detection.Backend
  def options,
    do:
      [:hef_path, :score_threshold, :executable, :working_directory, :library_path] ++
        PortBackend.options()

  @doc "`:running` while the Port is open, `:failed` otherwise, the Port gone included."
  @impl VisionCore.Detection.Backend
  def state({process, _lane}), do: PortBackend.state(process)

  @impl VisionCore.Detection.Backend
  def npu_kind, do: "Hailo-8"

  @doc """
  The inference step of the detection pipeline `settings.pipeline`,
  which `VisionCore.Hailo` declares: its model and threshold.
  """
  @spec inference_group(%{
          :pipeline => atom(),
          :hef_path => Path.t(),
          :score_threshold => float(),
          optional(atom()) => term()
        }) :: VisionCore.Parameters.group_declaration()
  def inference_group(settings) do
    Pipeline.inference_group(settings.pipeline, %{
      summary: "Finds objects in the image on the Hailo-8.",
      explanation: @explanation,
      compute: %{runs_on: :npu, implementation: :rust, backend: nil},
      parameters: [
        Parameters.build_parameter(
          {:model, Path.basename(settings.hef_path)},
          "The compiled model the accelerator runs"
        ),
        Parameters.build_parameter(
          {:score_threshold, settings.score_threshold},
          "Lowest score the accelerator reports"
        )
      ]
    })
  end
end
