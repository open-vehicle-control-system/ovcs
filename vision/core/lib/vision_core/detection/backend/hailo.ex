defmodule VisionCore.Detection.Backend.Hailo do
  @moduledoc """
  The `hailo_detect` Port: one YOLO HEF loaded on the Hailo-8, one
  inference in flight at a time, run by
  `VisionCore.Inference.PortBackend`.

  A Port rather than a NIF. An inference blocks `hailo_detect` for
  milliseconds — over the NIF budget by a wide margin, and a
  scheduler hazard — while an OS process blocking is a non-event. It
  also means a Hailo fault kills a process the supervisor restarts,
  not the BEAM, so the stereo depth path survives it.

  ## Backpressure

  `detect/3` is asynchronous and **drops** the frame if inference is
  already running, answering `{:error, :busy}`. That is the right
  behaviour for a live sensor: inference is far faster than the stereo
  frame rate, so a drop means something is badly wrong, and queueing
  frames would only add latency to a measurement whose whole value is
  being current.

  The caller receives `{:inference_detections, sequence, detections}` where
  each detection is

      %{class_id: 0..79, score: 0.0..1.0, x0:, y0:, x1:, y1:}

  in the **submitted image's** pixel coordinates — the Port owns the
  letterbox transform in both directions, so nothing here has to know
  the model's input size.

  ## Failure is not fatal

  A missing binary or HEF is logged and leaves this process alive but
  inference-less, answering `{:error, :unavailable}`. A Port that could
  not be opened for another reason is tried again. When `hailo_detect`
  exits, as it does when the accelerator is not ready yet or after a
  failed read, or leaves a frame unanswered for `:infer_timeout_ms`, the
  frame in flight is answered with `nil` detections and the Port is
  reopened after a wait that grows with each failure in a row
  (`:reopen_delays_ms`), answering `{:error, :unavailable}` meanwhile. A
  detection reply starts the waits over. The stereo pipeline never
  depends on the detector being up.

  ## Options

    * `:hef_path` — the model (required).
    * `:name` (the module) — the name it registers under.
    * `:pipeline` (`:detection`) — the detection pipeline whose inference
      step it declares.
    * `:score_threshold` (`0.4`) — the lowest score `hailo_detect` reports.
    * `:executable` — the program (default `priv/hailo_detect`).
    * `:working_directory` (`"/data"`) — where `hailo_detect` runs;
      libhailort writes its log there.
    * `:library_path` — where libhailort is (default `Hailort.lib_dir/0`).
    * `:infer_timeout_ms` (`2000`), `:reopen_delays_ms`
      (`[1000, 2000, 5000, 10000, 30000]`, the last repeated);
      another value than `VisionCore.Inference.PortBackend.timings!/1`
      takes fails the start.
  """
  @behaviour VisionCore.Detection.Backend
  @behaviour VisionCore.Inference.PortBackend

  alias VisionCore.Detection.Backend.Wire
  alias VisionCore.Detection.Pipeline
  alias VisionCore.Inference.PortBackend
  alias VisionCore.Stereo.Parameters

  # :hailort is a dependency only on targets that build hailo_detect.
  @compile {:no_warn_undefined, Hailort}

  @default_score_threshold 0.4
  @explanation "Runs object detection on the Hailo-8 accelerator. It finds people, vehicles, " <>
                 "animals and everyday objects, the 80 COCO classes, each as a box with a score. " <>
                 "The model and score_threshold, the lowest score the accelerator reports, are " <>
                 "fixed in the build. When the accelerator is not ready, inference waits and " <>
                 "starts again, and the depth carries on without it: Hailo in the top bar shows " <>
                 "its state."

  @doc false
  def child_spec(opts), do: %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}}

  def start_link(opts), do: PortBackend.start_link(__MODULE__, opts)

  @doc """
  Submit a `u8` `{height, width}` (or `{height, width, 3}` RGB) tensor
  for detection. Returns `:ok` when the frame was handed to the
  accelerator, `{:error, :busy}` when one is already in flight, and
  `{:error, :unavailable}` without a Port.
  """
  @impl VisionCore.Detection.Backend
  def detect(server \\ __MODULE__, sequence, image),
    do: PortBackend.submit(server, sequence, image)

  @doc """
  Whether the accelerator is loaded and answering, an inference in
  flight or not: at the stereo frame rate there usually is one.
  """
  @impl VisionCore.Detection.Backend
  def available?(server \\ __MODULE__), do: PortBackend.available?(server)

  @doc """
  The sum and the count of the inference times `hailo_detect` reported since the
  last call, in microseconds, which this starts again; `nil` until it has
  reported one since the Port last opened, and when the backend is gone.
  """
  @impl VisionCore.Detection.Backend
  def inference_times(server \\ __MODULE__), do: PortBackend.inference_times(server)

  @impl VisionCore.Detection.Backend
  def options,
    do:
      [:hef_path, :score_threshold, :executable, :working_directory, :library_path] ++
        PortBackend.options()

  @doc "`:running` while the Port is open, `:failed` otherwise, the backend gone included."
  @impl VisionCore.Detection.Backend
  def state(server \\ __MODULE__), do: PortBackend.state(server)

  @impl VisionCore.Detection.Backend
  def npu_kind, do: "Hailo-8"

  @impl PortBackend
  def init(opts) do
    %{
      pipeline: Keyword.get(opts, :pipeline, :detection),
      executable: Keyword.get_lazy(opts, :executable, &default_executable_path/0),
      hef_path: Keyword.fetch!(opts, :hef_path),
      score_threshold: Keyword.get(opts, :score_threshold, @default_score_threshold),
      working_directory: Keyword.get(opts, :working_directory, "/data"),
      library_path: Keyword.get(opts, :library_path)
    }
  end

  @impl PortBackend
  def wording(settings) do
    %{
      label: "#{inspect(__MODULE__)} (#{settings.pipeline})",
      program: "hailo_detect",
      loaded: "loaded #{Path.basename(settings.hef_path)} (score >= #{settings.score_threshold})",
      input: "frame",
      output: "detections"
    }
  end

  @impl PortBackend
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

  @impl PortBackend
  def open(%{executable: executable, hef_path: hef_path} = settings, nil) do
    cond do
      not File.exists?(executable) -> {:error, {:missing_binary, executable}}
      not File.exists?(hef_path) -> {:error, {:missing_hef, hef_path}}
      true -> spawn_detector_port(settings)
    end
  end

  defp spawn_detector_port(settings) do
    port =
      Port.open({:spawn_executable, settings.executable}, [
        :binary,
        :exit_status,
        {:packet, 4},
        {:cd, String.to_charlist(settings.working_directory)},
        {:env,
         [{~c"LD_LIBRARY_PATH", String.to_charlist(settings.library_path || Hailort.lib_dir())}]},
        {:args, [settings.hef_path, to_string(settings.score_threshold)]}
      ])

    {:ok, port}
  rescue
    error -> {:error, error}
  end

  @impl PortBackend
  def final?({missing, _path}) when missing in [:missing_binary, :missing_hef], do: true
  def final?(_reason), do: false

  @impl PortBackend
  defdelegate request(sequence, image), to: Wire

  @impl PortBackend
  defdelegate parse(packet), to: Wire

  @impl PortBackend
  def reply_tag, do: :inference_detections

  defp default_executable_path, do: :vision_core |> :code.priv_dir() |> Path.join("hailo_detect")
end
