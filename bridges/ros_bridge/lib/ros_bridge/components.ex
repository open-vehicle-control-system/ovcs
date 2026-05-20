defmodule RosBridge.Components do
  @moduledoc """
  Resolves the symbolic component entries in a vehicle's
  `RosBridge.Config.components` list into supervised child specs.

  Each clause of `start/2` returns a list of one or more child specs
  for the named component. Vehicles compose `ros_bridge` by listing
  the components they want; adding a new feature is one new clause
  here plus one opt-in line per vehicle that wants it. No implicit
  defaults — the bridge's runtime shape is exactly what the active
  vehicle declared.

  ## Components today

    * `:heartbeat` — `RosBridge.Publishers.Heartbeat` publishing a 1 Hz
      `std_msgs/String` on `/ovcs_heartbeat`. Opts:
        * `:interval_ms` (default `1_000`)
    * `:joy_interpreter` — `RosBridge.Consumers.Joy` subscribing to
      `/joy` and forwarding axes onto the CAN bus. No opts.
    * `:imu_publisher` — starts the named driver (any
      `OvcsDrivers.Imu` implementation) followed by
      `RosBridge.Publishers.Imu`. Opts:
        * `:driver` (required, module — `OvcsDrivers.Imu.Dummy`,
          `BNO085.I2C`, etc.)
        * `:topic`, `:frame_id`, `:publish_interval_ms` — forwarded
          to `RosBridge.Publishers.Imu` (see its defaults).
    * `:stereo_camera` — self-contained stereo perception unit
      (cameras + per-side image/camera_info publishers + SGBM
      backend + disparity/depth publisher). All orchestration
      lives in `RosBridge.StereoCamera.Supervisor`; see that
      module's `@moduledoc` for the authoritative opts reference.
      Minimal vehicle wiring looks like:

          {:stereo_camera,
           driver: RosBridge.Camera.GStreamer,
           calibration_dir: :code.priv_dir(:ovcs_mini)
                            |> Path.join("calibration"),
           left:  [device: "/dev/video2"],
           right: [device: "/dev/video0"]}

      Resolution defaults to 1280×720@30, topic prefix to
      `"stereo"` (matching the ROS `stereo_image_proc` convention),
      and per-side `frame_id` / `calibration_path` to values
      derived from `:topic_prefix` and `:calibration_dir`. The
      stereo-depth backend is hardcoded to
      `RosBridge.StereoCamera.OpenCV`; if/when a second backend
      lands we'll reintroduce a behaviour + `:backend` opt.
  """

  @doc """
  Returns the child specs to start `component` with `opts`. Raises on
  unknown names so a typo in a vehicle's `:components` list fails
  loudly at boot.
  """
  def start(:heartbeat, opts) do
    [
      {RosBridge.Publishers.Heartbeat,
       topic: "ovcs_heartbeat",
       message_module: Ros2.StdMsgs.Msg.String,
       interval_ms: Keyword.get(opts, :interval_ms, 1_000),
       build: &heartbeat_message/1}
    ]
  end

  def start(:joy_interpreter, _opts), do: [{RosBridge.Consumers.Joy, []}]

  def start(:imu_publisher, opts) do
    driver = Keyword.fetch!(opts, :driver)
    [{driver, []}, {RosBridge.Publishers.Imu, opts}]
  end

  def start(:stereo_camera, opts) do
    # Everything :stereo_camera needs to do — start two camera
    # drivers, the SGBM backend, and the unified publisher that
    # emits per-side images + disparity + depth — is owned by a
    # dedicated supervisor. See `RosBridge.StereoCamera.Supervisor`
    # for the full set of opts (driver, left, right, etc.).
    [{RosBridge.StereoCamera.Supervisor, opts}]
  end

  defp heartbeat_message(counter) do
    %Ros2.StdMsgs.Msg.String{
      data: "heartbeat #{counter} @ #{System.system_time(:millisecond)}"
    }
  end
end
