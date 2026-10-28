defmodule VisionCore.Components do
  @moduledoc """
  Resolves the symbolic entries of `VisionCore.Config.components` into
  supervised child specs.

  Each clause of `start/2` returns the child specs of one component. The
  runtime shape is exactly what the vehicle declared; there are no
  implicit defaults.

  ## Components

    * `:heartbeat` — `VisionCore.Ros2.Publishers.Heartbeat` publishing a 1 Hz
      `std_msgs/String` on `/ovcs_heartbeat`. Opts:
        * `:interval_ms` (default `1_000`)
    * `:simulator_clock` — `VisionCore.Ros2.Clock`, following `/clock` so
      published stamps use simulator time rather than wall clock.
      **Simulation only.** Without it every stamp is wall clock, which
      is correct on a vehicle and wrong against Gazebo — see
      `VisionCore.Ros2.Clock` for what that breaks.
    * `:stereo_camera` — self-contained stereo perception unit (cameras,
      per-side image and camera_info publishers, SGBM backend,
      disparity/depth publisher). All orchestration lives in
      `VisionCore.StereoCamera.Supervisor`; see its `@moduledoc` for the
      authoritative opts reference. Minimal wiring:

          {:stereo_camera,
           driver: VisionCore.Camera.GStreamer,
           calibration_dir: calibration_dir,
           left: [device: "/dev/video2"],
           right: [device: "/dev/video0"]}

      The stereo-depth backend is `VisionCore.StereoCamera.OpenCV`.
    * `:detector` — `VisionCore.Inference.Supervisor` with the `:backend`
      given in the opts (`VisionCore.Inference.Hailo`, `.Dnn`, `.Stub`).
      List it after `:stereo_camera`: the detector registers on that
      unit's backend while starting.
    * `:hailo_detector` — `:detector` with the Hailo backend.
  """

  @doc """
  Returns the child specs to start `component` with `opts`. Raises on
  unknown names so a typo in a vehicle's `:components` list fails
  loudly at boot.
  """
  @spec start(atom(), keyword()) :: [Supervisor.child_spec() | {module(), term()}]
  def start(:heartbeat, opts) do
    [
      {VisionCore.Ros2.Publishers.Heartbeat,
       topic: "ovcs_heartbeat",
       message_module: Ros2Zenoh.StdMsgs.Msg.String,
       interval_ms: Keyword.get(opts, :interval_ms, 1_000),
       build: &heartbeat_message/2}
    ]
  end

  def start(:simulator_clock, opts), do: [{VisionCore.Ros2.Clock, opts}]

  def start(:hailo_detector, opts) do
    start(:detector, Keyword.put_new(opts, :backend, VisionCore.Inference.Hailo))
  end

  def start(:detector, opts) do
    # Its own supervisor, so a crashing detector cannot exhaust the pipeline's restart budget.
    [{VisionCore.Inference.Supervisor, opts}]
  end

  def start(:stereo_camera, opts) do
    # Not restarted once it gives up, so a dead camera cannot exhaust the pipeline's budget.
    [Supervisor.child_spec({VisionCore.StereoCamera.Supervisor, opts}, restart: :transient)]
  end

  defp heartbeat_message(counter, node_name) do
    %Ros2Zenoh.StdMsgs.Msg.String{
      data: "#{node_name} heartbeat #{counter} @ #{System.system_time(:millisecond)}"
    }
  end
end
