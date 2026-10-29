defmodule VisionCore.Detection.Supervisor do
  @moduledoc """
  Supervises the detection unit: an inference backend, the
  `VisionCore.Detection.Pipeline` that places its boxes in 3D with the
  stereo depth, and the `VisionCore.Ros2.Publishers.Detections` that
  publishes them.

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
  every later answer as stale. Restarting it alongside clears that, and
  the publisher after it registers on the new pipeline. Not the
  reverse: a backend is told where to reply on every call and holds
  nothing across one.

  Options other than the backend's go to the pipeline and the
  publisher; see their docs.
  """
  use Supervisor

  alias VisionCore.Detection.Pipeline
  alias VisionCore.Ros2.Publishers.Detections

  @default_backend VisionCore.Detection.Backend.Hailo
  # Its own budget, so a crash loop stops here instead of in the vision core supervisor.
  @max_restarts 10
  @max_seconds 60

  def start_link(opts), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl Supervisor
  def init(opts) do
    {backend, backend_opts} = split_backend_options(opts)

    rest = Keyword.drop(opts, [:backend | backend_keys()])

    children = [
      {backend, backend_opts},
      # The backend module is also its registered name, so the
      # pipeline needs nothing but the module to reach it.
      {Pipeline, rest |> Keyword.take(pipeline_keys()) |> Keyword.put(:backend, backend)},
      {Detections, Keyword.drop(rest, pipeline_keys())}
    ]

    Supervisor.init(children,
      strategy: :rest_for_one,
      max_restarts: @max_restarts,
      max_seconds: @max_seconds
    )
  end

  defp split_backend_options(opts) do
    backend = Keyword.get(opts, :backend, @default_backend)
    {backend, Keyword.take(opts, backend_keys())}
  end

  defp pipeline_keys,
    do: [:detect_every_n, :labels, :min_score, :max_detections, :depth_sample_fraction]

  defp backend_keys do
    [:hef_path, :model_path, :target, :score_threshold, :nms_threshold, :input_size, :boxes]
  end
end
