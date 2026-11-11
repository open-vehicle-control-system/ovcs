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
      first. Several detectors run side by side, each with its own
      `:name` (`VisionCore.Detection`), the child id of its unit.
    * `:hailo_detector` — `:detector` with the Hailo backend.
    * `:qnn_detector` — `:detector` with the QNN backend
      (`VisionCore.Detection.Backend.Qnn`), on a Qualcomm Hexagon NPU.
    * `:camera` — `VisionCore.Camera.Unit`: a camera of its own, outside
      the stereo pair, its `:name` the child id of its unit, `{:camera,
      name}`, and its frames the output `{:camera_frame, name}`. `:name`
      and `:driver` are required; the other options go to the driver:

          {:camera,
           name: :hq,
           driver: VisionCore.Camera.V4L2Single,
           csiphy: 2,
           frame_id: "hq_camera_optical"}

      or, on a workstation, `driver: VisionCore.Camera.GStreamer, device:
      "/dev/video0"`.
  """

  alias VisionCore.Detection

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
    id =
      Detection.server(
        Detection.Supervisor,
        opts |> Detection.pipeline_name() |> Detection.name!()
      )

    # Its own budget, and not restarted once it gives up, so a crashing detector cannot exhaust the vision core's.
    [Supervisor.child_spec({VisionCore.Detection.Supervisor, opts}, id: id, restart: :transient)]
  end

  def start(:camera, opts) do
    name = VisionCore.Camera.Unit.name!(opts)

    [
      Supervisor.child_spec({VisionCore.Camera.Unit, opts},
        id: {:camera, name},
        restart: :transient
      )
    ]
  end

  def start(:stereo, opts) do
    # Not restarted once it gives up, so a dead camera cannot exhaust the vision core's budget.
    [Supervisor.child_spec({VisionCore.Stereo.Supervisor, opts}, restart: :transient)]
  end
end
