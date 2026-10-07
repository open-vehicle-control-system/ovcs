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
         - `<topic_prefix>/depth/image_rect` (Image 32FC1, metres),
         - `<topic_prefix>/depth/camera_info` — the same intrinsics as
           the left camera, republished as a *sibling* of the depth
           image. Consumers resolve a camera_info by convention from
           the image's own namespace, so without this a viewer cannot
           project the depth image and silently renders nothing,
         - `<topic_prefix>/disparity/image` (Image 32FC1, pixels) only
           when `:publish_disparity_image` is set — see below,
         - `<topic_prefix>/left/image_rect/compressed` (JPEG) only when
           `:publish_rectified_image` is set — see below.

    4. `RosBridge.StereoCamera.Parameters`, the unit's settings as ROS
       2 parameters of the bridge's node.
    5. `RosBridge.StereoCamera.Live`, what the cameras actually apply
       and their sync, on `/diagnostics` and `<topic_prefix>/live/*`.

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
    * `:publish_disparity_image` (`false`) — also publish the
      disparity pixels as a bare `sensor_msgs/Image`, because viewers
      match on a topic's type and cannot render the `DisparityImage`
      container. Off by default: it is a third uncompressed 921 KB
      image per frame, and at 640x360 / 7 Hz the three together ask
      for ~19 MB/s from one Zenoh session. Measured on ovcs_mini,
      turning it on dropped `depth/image_rect` from ~7 Hz to 1.3 Hz
      while only 9.6 MB/s arrived — so this is a debugging aid to
      switch on deliberately, not something to leave running.
    * `:publish_rectified_image` (`false`) — also publish the
      rectified left image, pixel-aligned with the depth image and
      stamped like it, for consumers that pair the two (RGB-D SLAM).
      Its intrinsics are `<topic_prefix>/depth/camera_info`;
      `<topic_prefix>/left/camera_info` describes the raw image.
    * `:topic_prefix` (`"stereo"`) — root of every topic this
      unit publishes. Also drives the default `frame_id` for each
      side (`<prefix>_left`, `<prefix>_right`).
    * `:calibration_dir` — when set, the per-side
      `calibration_path` defaults to
      `<calibration_dir>/<topic_prefix>_<side>.yaml`.
    * `:calibration_store_dir` — a writable directory for
      calibrations committed at runtime (`cameracalibrator`'s
      COMMIT), as `<topic_prefix>_<side>.yaml`. When both sides are
      stored there they take precedence over `calibration_path`, so
      a calibration survives a restart on a read-only root
      filesystem. Without it, COMMIT writes to `calibration_path`.
    * `:pair_tolerance_ms` (33).
    * `:backend_opts` (`[]`) — forwarded to
      `RosBridge.StereoCamera.OpenCV`'s `start_link/1`. The per-side
      `:calibration_path` is auto-injected as
      `:left_calibration_path` / `:right_calibration_path`, so
      vehicles don't have to specify them at two levels.
  """
  use Supervisor
  require Logger

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
    # `:rest_for_one`, not `:one_for_one`: the pipeline is wired by
    # init-time registration (the publisher casts `register_listener`
    # to both drivers and to the backend), and the drivers stop
    # deliberately when their subprocess exits, so restart is a
    # designed path. Under `:one_for_one` a restarted driver came back
    # with `listeners: []` and never delivered another frame, and a
    # restarted backend left the publisher `awaiting_result: true`
    # forever, dropping every pair as `drop_busy` — both silently.
    # Child order (drivers, backend, publisher, services) means
    # restarting any child also restarts everything downstream of it,
    # which re-runs the registrations.
    Supervisor.init(child_specs(config), strategy: :rest_for_one)
  end

  # ── config resolution ────────────────────────────────────────

  defp build_config(opts) do
    topic_prefix = Keyword.get(opts, :topic_prefix, @default_topic_prefix)
    calibration_dir = Keyword.get(opts, :calibration_dir)
    store_dir = Keyword.get(opts, :calibration_store_dir)

    left =
      resolve_side_opts(Keyword.fetch!(opts, :left), :left, topic_prefix, calibration_dir)

    right =
      resolve_side_opts(Keyword.fetch!(opts, :right), :right, topic_prefix, calibration_dir)

    {left, right} = use_stored_calibration(left, right, store_dir, topic_prefix)

    %{
      driver: Keyword.fetch!(opts, :driver),
      width: Keyword.get(opts, :width, @default_width),
      height: Keyword.get(opts, :height, @default_height),
      fps: Keyword.get(opts, :fps, @default_fps),
      topic_prefix: topic_prefix,
      pair_tolerance_ms: Keyword.get(opts, :pair_tolerance_ms, @default_pair_tolerance_ms),
      publish_disparity_image: Keyword.get(opts, :publish_disparity_image, false),
      publish_rectified_image: Keyword.get(opts, :publish_rectified_image, false),
      backend_opts: Keyword.get(opts, :backend_opts, []),
      left: left,
      right: right
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

  @doc """
  The per-side opts with `:calibration_store_path` set from
  `store_dir`, and `:calibration_path` pointing at the stored files
  when both sides are stored: one stored side alone would pair two
  calibrations solved apart. Unchanged when `store_dir` is `nil`.
  """
  def use_stored_calibration(left, right, nil, _topic_prefix), do: {left, right}

  def use_stored_calibration(left, right, store_dir, topic_prefix) do
    left_store = Path.join(store_dir, "#{topic_prefix}_left.yaml")
    right_store = Path.join(store_dir, "#{topic_prefix}_right.yaml")
    left = Keyword.put(left, :calibration_store_path, left_store)
    right = Keyword.put(right, :calibration_store_path, right_store)

    if File.exists?(left_store) and File.exists?(right_store) do
      Logger.info("#{__MODULE__} using the calibration stored in #{store_dir}")

      {Keyword.put(left, :calibration_path, left_store),
       Keyword.put(right, :calibration_path, right_store)}
    else
      {left, right}
    end
  end

  @doc """
  Reloads the backend from the stored calibration once both sides
  are stored. COMMIT stores one side at a time.
  """
  def reload_stored_calibration(backend, left_store, right_store) do
    if File.exists?(left_store) and File.exists?(right_store) do
      OpenCV.reload_calibration(backend,
        left_calibration_path: left_store,
        right_calibration_path: right_store
      )
    else
      :ok
    end
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
      stereo_publisher_spec(config),
      Supervisor.child_spec(
        {RosBridge.StereoCamera.Parameters,
         topic_prefix: config.topic_prefix,
         driver: config.driver,
         left: config.left,
         right: config.right,
         width: config.width,
         height: config.height,
         fps: config.fps},
        id: {:stereo, :parameters}
      ),
      Supervisor.child_spec(
        {RosBridge.StereoCamera.Live,
         topic_prefix: config.topic_prefix,
         driver: config.driver,
         left: config.left,
         right: config.right,
         fps: config.fps},
        id: {:stereo, :live}
      )
    ] ++ set_camera_info_specs(config)
  end

  # Per-side `set_camera_info` service server. Together they let
  # `cameracalibrator`'s COMMIT button persist the new calibration
  # (to the store when there is one, else over the YAML loaded at
  # boot) and hot-reload the SGBM backend so the change takes effect
  # without restarting.
  defp set_camera_info_specs(config) do
    Enum.flat_map([:left, :right], fn side ->
      side_opts = Map.fetch!(config, side)
      service_name = "#{config.topic_prefix}/#{side}/set_camera_info"

      case Keyword.get(side_opts, :calibration_store_path, side_opts[:calibration_path]) do
        nil ->
          []

        path ->
          [
            Supervisor.child_spec(
              {RosBridge.Services.SetCameraInfoServer,
               service_name: service_name,
               calibration_path: path,
               camera_name: "#{config.topic_prefix}_#{side}",
               reload: reload_callback(config)},
              id: {:stereo, :set_camera_info, side}
            )
          ]
      end
    end)
  end

  defp reload_callback(config) do
    case {config.left[:calibration_store_path], config.right[:calibration_store_path]} do
      {nil, nil} ->
        {OpenCV, :reload_calibration, [OpenCV]}

      {left_store, right_store} ->
        {__MODULE__, :reload_stored_calibration, [OpenCV, left_store, right_store]}
    end
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
      |> Keyword.delete(:calibration_store_path)
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
      disparity_image_topic:
        config.publish_disparity_image && "#{config.topic_prefix}/disparity/image",
      depth_topic: "#{config.topic_prefix}/depth/image_rect",
      depth_camera_info_topic: "#{config.topic_prefix}/depth/camera_info",
      cloud_topic: "#{config.topic_prefix}/points",
      rectified_image_topic:
        config.publish_rectified_image && "#{config.topic_prefix}/left/image_rect/compressed",
      pair_tolerance_ms: config.pair_tolerance_ms
    ]

    {RosBridge.Publishers.StereoCamera, publisher_opts}
  end
end
