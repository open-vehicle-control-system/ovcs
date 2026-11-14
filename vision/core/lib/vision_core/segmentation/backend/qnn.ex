defmodule VisionCore.Segmentation.Backend.Qnn do
  @moduledoc """
  The `qnn_segment` Port: a segmentation model on a Qualcomm Hexagon
  NPU through QNN, as on the Arduino VENTUNO Q, one band in flight at a
  time, run by `VisionCore.Inference.PortBackend`. The Port stretches the band it is sent onto the
  model's input and answers each cell of the model's output grid with
  the class scoring highest.

  The model is a DLC whose context binary is generated on the board the
  first time and cached (`VisionCore.Inference.QnnContext`), in a task:
  until the Port opens on it, `segment/3` answers `{:error, :unavailable}`
  at once, so the pipeline skips its frames instead of waiting.

  The contract is `VisionCore.Segmentation.Backend`'s: `segment/3` hands
  a band over or answers `{:error, :busy}` while one is in flight, the
  caller receives `{:inference_labels, sequence, labels}`, `nil` labels
  for a band the Port could not segment, and a missing DLC, QAIRT or
  binary leaves the process alive answering `{:error, :unavailable}`. When `qnn_segment`
  exits or leaves a band unanswered for `:infer_timeout_ms`, the band in
  flight is answered with `nil` labels and the Port is reopened after a
  wait that grows with each failure in a row, as
  `VisionCore.Detection.Backend.Qnn` does, and as it tries again a
  context binary that could not be generated.

  The band goes to the Port as an image of its own whose band is all of
  it, so only its rows go down the pipe.

  ## Options

    * `:dlc_path` — the model (required).
    * `:pipeline` — the segmentation pipeline whose inference step it
      declares (required).
    * `:classes` (19, the Cityscapes classes) — the number of classes
      the pipeline names, which `qnn_segment` refuses a model scoring
      another number of.
    * `:qairt_dir`, `:dsp_library_path` and `:dsp_architecture` — where
      QNN is on the board (`VisionCore.Inference.QnnPort`).
    * `:name` (the module) — the name it registers under.
    * `:cache_dir` (`"/data/vision/qnn/<pipeline>"`) — where the context
      binary is kept, which `VisionCore.Inference.QnnContext` keeps alone
      in it.
    * `:executable` — the program (default `priv/qnn_segment`).
    * `:infer_timeout_ms` (`2000`), a positive integer, and
      `:reopen_delays_ms` (`[1000, 2000, 5000, 10000, 30000]`, the last
      repeated), a non-empty list of non-negative integers; another value
      fails the start (`VisionCore.Inference.PortBackend.timings!/1`).
    * `:performance` (`qnn_segment`'s own, `:burst`) — the performance
      profile the Port votes on the HTP, and `:rpc_polling_us`
      (`qnn_segment`'s own, 0) — how long its thread polls for an
      execution's end before it sleeps until the NPU signals it; another
      value fails the start (`VisionCore.Inference.QnnPort.power_args!/1`).
  """
  @behaviour VisionCore.Segmentation.Backend
  @behaviour VisionCore.Inference.PortBackend

  alias VisionCore.Inference.QnnPort
  alias VisionCore.Inference.PortBackend
  alias VisionCore.Stereo.Parameters

  # Port protocol tag; must match `qnn_segment`.
  @segment_tag 7

  @explanation "Classes each part of the image on the Hexagon NPU among the 19 Cityscapes " <>
                 "classes: road, sidewalk, buildings, vegetation, sky, people, vehicles and " <>
                 "the others. The model sees the band of the image the input step picks, " <>
                 "stretched to its input, and gives a class to each cell of its output grid. " <>
                 "The model and the NPU's power vote are fixed in the build. When the NPU is not ready, inference waits " <>
                 "and starts again, and the depth carries on without it."

  @doc false
  def child_spec(opts), do: %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}}

  def start_link(opts), do: PortBackend.start_link(__MODULE__, opts)

  @doc """
  Submit a band for segmentation: `:ok` when handed to the NPU,
  `{:error, :busy}` while a band is in flight, `{:error, :unavailable}`
  without a Port.
  """
  @impl VisionCore.Segmentation.Backend
  def segment(server \\ __MODULE__, sequence, band),
    do: PortBackend.submit(server, sequence, band)

  @doc "Whether the Port is open, a band in flight or not."
  @impl VisionCore.Segmentation.Backend
  def available?(server \\ __MODULE__), do: PortBackend.available?(server)

  @doc """
  The sum and the count of the inference times `qnn_segment` reported
  since the last call, in microseconds, which this starts again; `nil`
  until it has reported one since the Port last opened, and when the
  backend is gone.
  """
  @impl VisionCore.Segmentation.Backend
  def inference_times(server \\ __MODULE__), do: PortBackend.inference_times(server)

  @impl VisionCore.Segmentation.Backend
  def options, do: [:dlc_path] ++ QnnPort.options() ++ PortBackend.options()

  @doc """
  `:starting` while the context binary is generated, `:running` once the
  Port is open, `:failed` otherwise, the backend gone included.
  """
  @impl VisionCore.Segmentation.Backend
  def state(server \\ __MODULE__), do: PortBackend.state(server)

  @impl VisionCore.Segmentation.Backend
  def npu_kind, do: "Hexagon"

  @impl PortBackend
  def init(opts) do
    pipeline = Keyword.fetch!(opts, :pipeline)

    %{
      pipeline: pipeline,
      dlc_path: Keyword.fetch!(opts, :dlc_path),
      power_args: QnnPort.power_args!(opts),
      power_parameters: QnnPort.power_parameters(opts),
      classes: Keyword.get(opts, :classes, length(VisionCore.Segmentation.labels())),
      runtime: QnnPort.runtime(opts),
      cache_dir: Keyword.get(opts, :cache_dir, "/data/vision/qnn/#{pipeline}"),
      executable: Keyword.get_lazy(opts, :executable, &default_executable_path/0)
    }
  end

  @impl PortBackend
  def wording(settings) do
    %{
      label: "#{inspect(__MODULE__)} (#{settings.pipeline})",
      program: "qnn_segment",
      loaded: "loaded #{Path.basename(settings.dlc_path)}",
      input: "band",
      output: "segmentation"
    }
  end

  @impl PortBackend
  def inference_group(settings) do
    VisionCore.Segmentation.inference_group(settings.pipeline, %{
      summary: "Classes each part of the image on the Hexagon NPU.",
      explanation: @explanation,
      compute: %{runs_on: :npu, implementation: :rust, backend: nil},
      parameters: [
        Parameters.build_parameter(
          {:model, Path.basename(settings.dlc_path)},
          "The model the NPU runs"
        ),
        Parameters.build_parameter(
          {:classes, settings.classes},
          "Classes the model scores, as many as the pipeline names"
        )
        | settings.power_parameters
      ]
    })
  end

  @impl PortBackend
  def prepare(settings), do: QnnPort.context(settings)

  @impl PortBackend
  def open(settings, context_binary) do
    args = [context_binary, Integer.to_string(settings.classes) | settings.power_args]
    QnnPort.open(settings.executable, args, settings.runtime)
  end

  @impl PortBackend
  defdelegate final?(reason), to: QnnPort

  @impl PortBackend
  def request(sequence, %{width: width, height: height, rgb: rgb}) do
    [
      <<@segment_tag, sequence::little-32, width::little-16, height::little-16, 3, 0::little-16,
        height::little-16>>,
      rgb
    ]
  end

  # The labels may be followed by the inference time, a `u32` in microseconds.
  @impl PortBackend
  def parse(
        <<@segment_tag, sequence::little-32, width::little-16, height::little-16, rest::binary>>
      ) do
    cells = width * height

    case rest do
      _empty when cells == 0 ->
        {:ok, sequence, nil, nil}

      <<data::binary-size(^cells), time_us::little-32, _rest::binary>> ->
        {:ok, sequence, %{width: width, height: height, data: data}, time_us}

      <<data::binary-size(^cells)>> ->
        {:ok, sequence, %{width: width, height: height, data: data}, nil}

      _short ->
        {:cut_short, sequence}
    end
  end

  def parse(_packet), do: :error

  @impl PortBackend
  def reply_tag, do: :inference_labels

  defp default_executable_path, do: :vision_core |> :code.priv_dir() |> Path.join("qnn_segment")
end
