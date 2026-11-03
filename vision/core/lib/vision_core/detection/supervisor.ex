defmodule VisionCore.Detection.Supervisor do
  @moduledoc """
  Supervises the detection unit: an inference backend, the
  `VisionCore.Detection.Pipeline` that places its boxes in 3D with the
  stereo depth, and `VisionCore.Detection.Live`, which hands them to the
  dashboard. `VisionCore.Ros2.Exporter` publishes them on ROS 2, outside
  the unit.

  Which backend is `:backend`, defaulting to the accelerator,
  `VisionCore.Detection.Backend.Hailo`. See `VisionCore.Detection.Backend`
  for `Stub`, for plumbing only.

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
  pipeline and `:max_hz` to `Live`; see their docs. The ROS 2 exporter
  reads `:topic_prefix`, `:frame_id`, `:marker_lifetime_ms` and
  `:label_font_size` (`VisionCore.Ros2.Exporter.Detections`).
  """
  use Supervisor

  alias VisionCore.Detection.{Live, Pipeline}

  @default_backend VisionCore.Detection.Backend.Hailo
  # Its own budget, so a crash loop stops here instead of in the vision core supervisor.
  @max_restarts 10
  @max_seconds 60

  def start_link(opts), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl Supervisor
  def init(opts) do
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
  def outputs(%VisionCore.Config{components: components}) do
    if Enum.any?(components, &starts_unit?/1),
      do: [detections: {:detections, Pipeline}],
      else: []
  end

  defp starts_unit?({name, opts}) do
    name
    |> VisionCore.Components.start(opts)
    |> Enum.any?(&match?(%{start: {__MODULE__, _function, _arguments}}, &1))
  end

  defp starts_unit?(name), do: starts_unit?({name, []})

  @doc false
  def split_backend_options(opts) do
    backend = Keyword.get(opts, :backend, @default_backend)
    {backend, Keyword.take(opts, backend_keys())}
  end

  defp pipeline_keys do
    [:detect_every_n, :labels, :min_score, :max_detections, :depth_sample_fraction] ++
      [:outline_segments]
  end

  # The options of `Backend.Hailo` and `Backend.Stub`.
  defp backend_keys do
    [:hef_path, :score_threshold, :executable, :working_directory, :library_path] ++
      [:infer_timeout_ms, :reopen_delays_ms, :boxes]
  end
end
