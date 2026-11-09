defmodule VisionCore.Components do
  @moduledoc """
  Resolves the symbolic entries of `VisionCore.Config.components` into
  supervised child specs.

  Each clause of `start/2` returns the child specs of one component. The
  runtime shape is exactly what the vehicle declared; there are no
  implicit defaults.

  The components produce the unit's outputs; what takes them out of the
  unit, such as `VisionCore.Ros2.Exporter`, is an exporter
  (`VisionCore.Config`'s `:exporters`).

  ## Components

    * `:stereo` — the stereo unit: two cameras, the pairer and the
      `VisionCore.Stereo.Pipeline` turning pairs into disparity and
      depth. `VisionCore.Stereo.Supervisor` documents the opts. Minimal
      wiring:

          {:stereo,
           driver: VisionCore.Camera.GStreamer,
           calibration_dir: calibration_dir,
           left: [device: "/dev/video2"],
           right: [device: "/dev/video0"]}

      `:stages` replaces the pipeline's default stages; see
      `VisionCore.Stereo.Pipeline.default_stages/1`.
    * `:detector` — `VisionCore.Detection.Supervisor`: the `:backend`
      given in the opts (`VisionCore.Detection.Backend.Hailo`, `.Qnn` or
      `.Stub`) and the `VisionCore.Detection.Pipeline` placing its boxes
      in 3D. The detection pipeline subscribes to the stereo pipeline's
      pairs through `VisionCore.Outputs`, whichever of the two starts
      first.
    * `:hailo_detector` — `:detector` with the Hailo backend.
    * `:qnn_detector` — `:detector` with the QNN backend
      (`VisionCore.Detection.Backend.Qnn`), on a Qualcomm Hexagon NPU.
  """

  @doc """
  Returns the child specs to start `component` with `opts`. Raises on
  unknown names so a typo in a vehicle's `:components` list fails
  loudly at boot.
  """
  @spec start(atom(), keyword()) :: [Supervisor.child_spec()]
  def start(:hailo_detector, opts) do
    start(:detector, Keyword.put_new(opts, :backend, VisionCore.Detection.Backend.Hailo))
  end

  def start(:qnn_detector, opts) do
    start(:detector, Keyword.put_new(opts, :backend, VisionCore.Detection.Backend.Qnn))
  end

  def start(:detector, opts) do
    # Its own budget, and not restarted once it gives up, so a crashing detector cannot exhaust the vision core's.
    [Supervisor.child_spec({VisionCore.Detection.Supervisor, opts}, restart: :transient)]
  end

  def start(:stereo, opts) do
    # Not restarted once it gives up, so a dead camera cannot exhaust the vision core's budget.
    [Supervisor.child_spec({VisionCore.Stereo.Supervisor, opts}, restart: :transient)]
  end
end
