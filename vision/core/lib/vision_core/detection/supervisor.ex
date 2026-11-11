defmodule VisionCore.Detection.Supervisor do
  @moduledoc """
  Supervises the detection unit: an inference backend, the
  `VisionCore.Detection.Pipeline` that places its boxes in 3D with the
  stereo depth, and `VisionCore.Detection.Live`, which hands them to the
  dashboard. `VisionCore.Ros2.Exporter` publishes them on ROS 2, outside
  the unit.

  Which backend is `:backend`, defaulting to the Hailo-8 accelerator,
  `VisionCore.Detection.Backend.Hailo`; `VisionCore.Detection.Backend.Qnn`
  runs on a Qualcomm Hexagon NPU. See `VisionCore.Detection.Backend` for
  `Stub`, for plumbing only.

  Exists to contain failure rather than to organise code. The vision
  core's own supervisor is `:rest_for_one` with the default restart
  intensity, and the detection pipeline handles a cast at the stereo
  frame rate — so a bug that raises on every frame would exhaust that
  budget almost at once and take the *whole* vision core down, cameras
  and depth included. Under this supervisor the same bug restarts the
  detector within its own budget and stops there, leaving the stereo
  unit untouched. Detections go away; depth does not.

  `:rest_for_one` because a backend restart strands the pipeline: it
  holds the pair whose image is at the accelerator and waits for a
  reply keyed on its sequence number. That reply is never coming, and
  nothing times it out, so it would hold a stale depth map and discard
  every later answer as stale. Restarting it alongside clears that. Not
  the reverse: a backend is told where to reply on every call and holds
  nothing across one.

  The backend's options go to the backend, the pipeline's to the
  pipeline and `:max_hz` to `Live`; see their docs. How the detections
  are published is the exporters' business: the ROS 2 exporter's are its
  `detections:` options (`VisionCore.Ros2.Exporter`), and their frame
  is the one their pair carries, the stereo unit's left `:frame_id`.

  A unit that fails to start, such as one whose backend cannot, or one
  given an option it does not take, is left down, with the reason
  logged, and the rest of the vision core runs on. The refusal of an
  option another component or exporter takes names where it belongs.
  """
  use Supervisor
  require Logger

  alias VisionCore.Detection.{Live, Pipeline}

  @default_backend VisionCore.Detection.Backend.Hailo
  # Its own budget, so a crash loop stops here instead of in the vision core supervisor.
  @max_restarts 10
  @max_seconds 60
  @exporter_options [:topic_prefix, :marker_lifetime_ms, :label_font_size]

  @doc """
  Starts the detection unit; see the module doc for `opts`. `:ignore`
  when it fails to start, so the vision core starts without it.
  """
  def start_link(opts) do
    case Supervisor.start_link(__MODULE__, opts, name: __MODULE__) do
      {:error, reason} ->
        Logger.error("#{__MODULE__} failed to start, detection down: #{failure_text(reason)}")
        :ignore

      started ->
        started
    end
  end

  defp failure_text({%{__exception__: true} = exception, _stacktrace}),
    do: Exception.message(exception)

  defp failure_text(reason), do: inspect(reason)

  @impl Supervisor
  def init(opts) do
    check_options!(opts)
    {backend, backend_opts} = split_backend_options(opts)

    children = [
      {backend, backend_opts},
      # The backend module is also its registered name, so the
      # pipeline needs nothing but the module to reach it.
      {Pipeline, opts |> Keyword.take(pipeline_keys()) |> Keyword.put(:backend, backend)},
      {Live, Keyword.take(opts, [:max_hz])}
    ]

    Supervisor.init(children,
      strategy: :rest_for_one,
      max_restarts: @max_restarts,
      max_seconds: @max_seconds
    )
  end

  @doc """
  The output of the detection unit in `config`, with its
  `VisionCore.Outputs` key: the detection pipeline's detections, as
  `VisionCore.Exporter` names them. `[]` when no component of `config`
  starts the unit, as `VisionCore.Components` resolves them.
  """
  @spec outputs(VisionCore.Config.t()) :: [
          {VisionCore.Exporter.output(), VisionCore.Outputs.key()}
        ]
  def outputs(config) do
    if unit_options(config), do: [detections: {:detections, Pipeline}], else: []
  end

  @doc """
  The backend module of the detection unit in `config`, `nil` when no
  component of `config` starts the unit.
  """
  @spec backend(VisionCore.Config.t()) :: module() | nil
  def backend(config) do
    case unit_options(config) do
      nil -> nil
      opts -> opts |> split_backend_options() |> elem(0)
    end
  end

  # The options of the unit `config`'s components start, as `VisionCore.Components` resolves them.
  defp unit_options(%VisionCore.Config{components: components}) do
    Enum.find_value(components, fn component ->
      {name, opts} = if is_atom(component), do: {component, []}, else: component

      Enum.find_value(VisionCore.Components.start(name, opts), fn
        %{start: {__MODULE__, _function, [unit_opts]}} -> unit_opts
        _child -> nil
      end)
    end)
  end

  defp check_options!(opts) do
    case Enum.uniq(Keyword.keys(opts)) -- options() do
      [] -> :ok
      refused -> raise ArgumentError, Enum.map_join(refused, "; ", &refused_option/1)
    end
  end

  defp refused_option(:frame_id),
    do: "its :frame_id is the stereo unit's: each side's :frame_id, which the pairs carry"

  defp refused_option(option) when option in @exporter_options,
    do:
      "its #{inspect(option)} is the ROS 2 exporter's detections: option " <>
        "(VisionCore.Ros2.Exporter)"

  defp refused_option(option), do: "it has no option #{inspect(option)}"

  defp options, do: [:backend, :max_hz] ++ pipeline_keys() ++ backend_keys()

  @doc false
  def split_backend_options(opts) do
    backend = Keyword.get(opts, :backend, @default_backend)
    {backend, Keyword.take(opts, backend_keys())}
  end

  defp pipeline_keys do
    [:detect_every_n, :labels, :min_score, :max_detections, :depth_sample_fraction] ++
      [:outline_segments]
  end

  # The options of `Backend.Hailo`, `Backend.Qnn` and `Backend.Stub`.
  defp backend_keys do
    [:hef_path, :score_threshold, :executable, :working_directory, :library_path] ++
      [:dlc_path, :qairt_dir, :dsp_library_path, :cache_dir] ++
      [:infer_timeout_ms, :reopen_delays_ms, :boxes]
  end
end
