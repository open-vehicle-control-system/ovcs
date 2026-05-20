defmodule RosBridge.StereoCamera.Supervisor do
  @moduledoc """
  Self-contained supervisor for one stereo perception unit. Owns:

    1. Two camera drivers (left + right) of the same `RosBridge.Camera`
       implementation.
    2. The stereo-depth backend `RosBridge.StereoCamera.OpenCV`.
    3. A `RosBridge.Publishers.StereoCamera` that subscribes to both
       drivers and publishes:
         - per-side `<topic_prefix>/<side>/image_raw/compressed`
           + `<topic_prefix>/<side>/camera_info`,
         - `<topic_prefix>/disparity` (DisparityImage),
         - `<topic_prefix>/depth/image_rect` (Image 32FC1, metres).

  Children start in that order so each downstream child can register
  on its upstream during `init/1`.

  ## Required opts

    * `:driver` — module implementing `RosBridge.Camera`.
      Same module for both sides; each side gets a separate
      GenServer instance addressed via the per-side opts.
    * `:left`, `:right` — keyword lists of per-side opts. Must
      contain the driver-specific addressing
      (`:device` for v4l2/gstreamer, `:camera_id` for libcamera).
      Optionally `:frame_id`, `:calibration_path` (override the
      defaults derived from `:topic_prefix` and `:calibration_dir`).

  ## Optional opts (sensible defaults)

    * `:width` (1280), `:height` (720), `:fps` (30) — applied to
      both camera drivers.
    * `:topic_prefix` (`"stereo"`) — root of every topic this
      unit publishes. Also drives the default `frame_id` for each
      side (`<prefix>_left`, `<prefix>_right`).
    * `:calibration_dir` — when set, the per-side
      `calibration_path` defaults to
      `<calibration_dir>/<topic_prefix>_<side>.yaml`.
    * `:pair_tolerance_ms` (33).
    * `:backend_opts` (`[]`) — forwarded to
      `RosBridge.StereoCamera.OpenCV`'s `start_link/1`. The per-side
      `:calibration_path` is auto-injected as
      `:left_calibration_path` / `:right_calibration_path`, so
      vehicles don't have to specify them at two levels.
  """
  use Supervisor

  alias RosBridge.StereoCamera.OpenCV

  @default_width 1280
  @default_height 720
  @default_fps 30
  @default_topic_prefix "stereo"
  @default_pair_tolerance_ms 33

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    config = build_config(opts)
    Supervisor.init(child_specs(config), strategy: :one_for_one)
  end

  # ── config resolution ────────────────────────────────────────

  defp build_config(opts) do
    topic_prefix = Keyword.get(opts, :topic_prefix, @default_topic_prefix)
    calibration_dir = Keyword.get(opts, :calibration_dir)

    %{
      driver: Keyword.fetch!(opts, :driver),
      width: Keyword.get(opts, :width, @default_width),
      height: Keyword.get(opts, :height, @default_height),
      fps: Keyword.get(opts, :fps, @default_fps),
      topic_prefix: topic_prefix,
      pair_tolerance_ms: Keyword.get(opts, :pair_tolerance_ms, @default_pair_tolerance_ms),
      backend_opts: Keyword.get(opts, :backend_opts, []),
      left:
        resolve_side_opts(
          Keyword.fetch!(opts, :left),
          :left,
          topic_prefix,
          calibration_dir
        ),
      right:
        resolve_side_opts(
          Keyword.fetch!(opts, :right),
          :right,
          topic_prefix,
          calibration_dir
        )
    }
  end

  defp resolve_side_opts(side_opts, side, topic_prefix, calibration_dir) do
    side_string = Atom.to_string(side)

    side_opts
    |> Keyword.put_new(:frame_id, "#{topic_prefix}_#{side_string}")
    |> Keyword.put_new_lazy(:calibration_path, fn ->
      default_calibration_path(calibration_dir, topic_prefix, side_string)
    end)
  end

  defp default_calibration_path(nil, _topic_prefix, _side), do: nil

  defp default_calibration_path(calibration_dir, topic_prefix, side) do
    Path.join(calibration_dir, "#{topic_prefix}_#{side}.yaml")
  end

  # ── child specs ──────────────────────────────────────────────

  defp child_specs(config) do
    [
      camera_driver_spec(config, :left),
      camera_driver_spec(config, :right),
      stereo_backend_spec(config),
      stereo_publisher_spec(config)
    ]
  end

  defp camera_driver_spec(config, side) do
    label = Atom.to_string(side)
    side_opts = Map.fetch!(config, side)

    driver_opts =
      side_opts
      |> Keyword.put(:label, label)
      |> Keyword.put_new(:width, config.width)
      |> Keyword.put_new(:height, config.height)
      |> Keyword.put_new(:fps, config.fps)
      # Strip publisher-only keys so the driver doesn't see them.
      |> Keyword.delete(:calibration_path)
      |> Keyword.delete(:frame_id)

    Supervisor.child_spec({config.driver, driver_opts}, id: {:stereo, :driver, side})
  end

  defp stereo_backend_spec(config) do
    # Push the per-side calibration paths AND the actual capture
    # resolution into the backend's opts so vehicles don't have to
    # specify them at two levels. The resolution lets the backend
    # scale the calibration matrices to match what the cameras
    # actually deliver — crucial when the calibration session was
    # captured at a different resolution.
    backend_opts =
      config.backend_opts
      |> Keyword.put_new(:left_calibration_path, config.left[:calibration_path])
      |> Keyword.put_new(:right_calibration_path, config.right[:calibration_path])
      |> Keyword.put_new(:width, config.width)
      |> Keyword.put_new(:height, config.height)

    {OpenCV, backend_opts}
  end

  defp stereo_publisher_spec(config) do
    publisher_opts = [
      cameras: [{config.driver, "left"}, {config.driver, "right"}],
      topic_prefix: config.topic_prefix,
      left: config.left,
      right: config.right,
      width: config.width,
      height: config.height,
      disparity_topic: "#{config.topic_prefix}/disparity",
      depth_topic: "#{config.topic_prefix}/depth/image_rect",
      pair_tolerance_ms: config.pair_tolerance_ms
    ]

    {RosBridge.Publishers.StereoCamera, publisher_opts}
  end
end
