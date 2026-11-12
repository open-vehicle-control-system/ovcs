defmodule VisionCore.Detection.Backend.Qnn do
  @moduledoc """
  The `qnn_detect` Port: YOLOX on a Qualcomm Hexagon NPU through QNN,
  as on the Arduino VENTUNO Q, one inference in flight at a time, run by
  `VisionCore.Inference.PortBackend`.

  The model is a DLC. Its context binary, tied to the chip and the QAIRT
  version, is generated on the board the first time and cached
  (`VisionCore.Inference.QnnContext`), in a task: until the Port opens
  on it, `detect/3` answers `{:error, :unavailable}` at once, so neither
  the vision core's start nor the pipeline's frames wait for a first
  boot's generation.

  The contract is `VisionCore.Detection.Backend`'s, as
  `VisionCore.Detection.Backend.Hailo` meets it: `detect/3` hands a
  frame over or answers `{:error, :busy}` while one is in flight, the
  caller receives `{:inference_detections, sequence, detections}` in the
  submitted image's pixels, and a missing DLC, QAIRT or binary leaves
  the process alive answering `{:error, :unavailable}`. When `qnn_detect`
  exits or leaves a frame unanswered for `:infer_timeout_ms`, the frame in
  flight is answered with `nil` detections and the Port is reopened after
  a wait that grows with each failure in a row. A context binary that
  could not be generated, or a Port that could not be opened, is tried
  again after the same waits.

  ## Options

    * `:dlc_path` — the model (required).
    * `:score_threshold` (`0.4`) — the lowest score `qnn_detect` reports.
    * `:qairt_dir`, `:dsp_library_path` and `:dsp_architecture` — where
      QNN is on the board (`VisionCore.Inference.QnnPort`).
    * `:name` (the module) — the name it registers under.
    * `:pipeline` (`:detection`) — the detection pipeline whose inference
      step it declares.
    * `:cache_dir` (`"/data/vision/qnn"`, `"/data/vision/qnn/<pipeline>"`
      for a pipeline other than `:detection`) — where the context binary
      is kept. `VisionCore.Inference.QnnContext` removes every other
      binary in it, so two pipelines never share one.
    * `:executable` — the program (default `priv/qnn_detect`).
    * `:infer_timeout_ms` (`2000`), a positive integer, and
      `:reopen_delays_ms` (`[1000, 2000, 5000, 10000, 30000]`, the last
      repeated), a non-empty list of non-negative integers; another value
      fails the start (`VisionCore.Inference.PortBackend.timings!/1`).
    * `:performance` (`qnn_detect`'s own, `:burst`) — the power vote the
      Port holds on the HTP; an unknown profile fails the start
      (`VisionCore.Inference.QnnPort.performance_args!/1`).
  """
  @behaviour VisionCore.Detection.Backend
  @behaviour VisionCore.Inference.PortBackend

  alias VisionCore.Detection.Backend.Wire
  alias VisionCore.Detection.Pipeline
  alias VisionCore.Inference.QnnPort
  alias VisionCore.Inference.PortBackend
  alias VisionCore.Stereo.Parameters

  @default_score_threshold 0.4
  @explanation "Runs object detection on the Hexagon NPU. It finds people, vehicles, " <>
                 "animals and everyday objects, the 80 COCO classes, each as a box with a score. " <>
                 "The model and score_threshold, the lowest score the NPU reports, are fixed in " <>
                 "the build. When the NPU is not ready, inference waits and starts again, and " <>
                 "the depth carries on without it."

  @doc false
  def child_spec(opts), do: %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}}

  def start_link(opts), do: PortBackend.start_link(__MODULE__, opts)

  @doc """
  Submit a `u8` `{height, width}` (or `{height, width, 3}` RGB) tensor
  for detection: `:ok` when handed to the NPU, `{:error, :busy}` while a
  frame is in flight, `{:error, :unavailable}` without a Port.
  """
  @impl VisionCore.Detection.Backend
  def detect(server \\ __MODULE__, sequence, image),
    do: PortBackend.submit(server, sequence, image)

  @doc "Whether the Port is open, an inference in flight or not."
  @impl VisionCore.Detection.Backend
  def available?(server \\ __MODULE__), do: PortBackend.available?(server)

  @doc """
  The sum and the count of the inference times `qnn_detect` reported since the
  last call, in microseconds, which this starts again; `nil` until it has
  reported one since the Port last opened, and when the backend is gone.
  """
  @impl VisionCore.Detection.Backend
  def inference_times(server \\ __MODULE__), do: PortBackend.inference_times(server)

  @impl VisionCore.Detection.Backend
  def options, do: [:dlc_path, :score_threshold] ++ QnnPort.options() ++ PortBackend.options()

  @doc """
  `:starting` while the context binary is generated, `:running` once the
  Port is open, `:failed` otherwise, the backend gone included.
  """
  @impl VisionCore.Detection.Backend
  def state(server \\ __MODULE__), do: PortBackend.state(server)

  @impl VisionCore.Detection.Backend
  def npu_kind, do: "Hexagon"

  @impl PortBackend
  def init(opts) do
    pipeline = Keyword.get(opts, :pipeline, :detection)

    %{
      pipeline: pipeline,
      dlc_path: Keyword.fetch!(opts, :dlc_path),
      performance_args: QnnPort.performance_args!(opts),
      score_threshold: Keyword.get(opts, :score_threshold, @default_score_threshold),
      runtime: QnnPort.runtime(opts),
      cache_dir: Keyword.get_lazy(opts, :cache_dir, fn -> default_cache_dir(pipeline) end),
      executable: Keyword.get_lazy(opts, :executable, &default_executable_path/0)
    }
  end

  @impl PortBackend
  def wording(settings) do
    %{
      label: label(settings),
      program: "qnn_detect",
      loaded: "loaded #{Path.basename(settings.dlc_path)} (score >= #{settings.score_threshold})",
      input: "frame",
      output: "detections"
    }
  end

  defp label(%{pipeline: :detection}), do: inspect(__MODULE__)
  defp label(%{pipeline: pipeline}), do: "#{inspect(__MODULE__)} (#{pipeline})"

  @impl PortBackend
  def inference_group(settings) do
    Pipeline.inference_group(settings.pipeline, %{
      summary: "Finds objects in the image on the Hexagon NPU.",
      explanation: @explanation,
      compute: %{runs_on: :npu, implementation: :rust, backend: nil},
      parameters: [
        Parameters.build_parameter(
          {:model, Path.basename(settings.dlc_path)},
          "The model the NPU runs"
        ),
        Parameters.build_parameter(
          {:score_threshold, settings.score_threshold},
          "Lowest score the NPU reports"
        )
      ]
    })
  end

  @impl PortBackend
  def prepare(settings), do: QnnPort.context(settings)

  @impl PortBackend
  def open(settings, context_binary) do
    args = [context_binary, to_string(settings.score_threshold) | settings.performance_args]
    QnnPort.open(settings.executable, args, settings.runtime)
  end

  @impl PortBackend
  defdelegate final?(reason), to: QnnPort

  @impl PortBackend
  defdelegate request(sequence, image), to: Wire

  @impl PortBackend
  defdelegate parse(packet), to: Wire

  @impl PortBackend
  def reply_tag, do: :inference_detections

  defp default_cache_dir(:detection), do: "/data/vision/qnn"
  defp default_cache_dir(pipeline), do: "/data/vision/qnn/#{pipeline}"

  defp default_executable_path, do: :vision_core |> :code.priv_dir() |> Path.join("qnn_detect")
end
