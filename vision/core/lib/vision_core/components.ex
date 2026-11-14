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
      `:name` (`VisionCore.Detection`), the child id of its unit. A
      named one with `source: {:camera, name}` detects on the camera of
      its own `name` instead, and takes the depth of the stereo pairs
      projected into that camera's image.
    * `:hailo_detector` — `:detector` with the Hailo backend.
    * `:qnn_detector` — `:detector` with the QNN backend
      (`VisionCore.Detection.Backend.Qnn`), on a Qualcomm Hexagon NPU.
    * `:segmenter` — `VisionCore.Segmentation.Supervisor`: a road
      segmentation pipeline on a camera of its own, `source: {:camera,
      name}`, its `:backend` `VisionCore.Segmentation.Backend.Qnn` by
      default. `:name` is required, the child id of its unit, and shares
      the detection pipelines' and the cameras' namespace
      (`VisionCore.Segmentation`):

          {:qnn_segmenter,
           name: :road,
           source: {:camera, :hq},
           dlc_path: Path.join(models_dir, "ffnet_122ns_lowres.dlc")}

    * `:qnn_segmenter` — `:segmenter` with the QNN backend, on a Qualcomm
      Hexagon NPU.
    * `:camera` — `VisionCore.Camera.Unit`: a camera of its own, outside
      the stereo pair, its `:name` the child id of its unit, `{:camera,
      name}`, and its frames the output `{:camera_frame, name}`, of its
      default output, or `{:camera_frame, name, output}`, of its output
      `output` (`VisionCore.Camera.Output`). `:name` and `:driver` are
      required; the other options go to the driver:

          {:camera,
           name: :hq,
           driver: VisionCore.Camera.V4L2Single,
           csiphy: 2,
           frame_id: "hq_camera_optical"}

      or, on a workstation, `driver: VisionCore.Camera.GStreamer, device:
      "/dev/video0"`. `:calibration`, `:calibration_store_dir` and
      `:pose` describe the camera to its consumers and are not the
      driver's (`VisionCore.Camera.Unit`).
  """

  alias VisionCore.{Detection, Pipelines}

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
      Pipelines.server(
        Detection.Supervisor,
        opts |> Detection.pipeline_name() |> Pipelines.name!()
      )

    # Its own budget, and restarted by VisionCore.Reviver alone once it gives up, so a crashing detector cannot exhaust the vision core's.
    [Supervisor.child_spec({VisionCore.Detection.Supervisor, opts}, id: id, restart: :transient)]
  end

  def start(:qnn_segmenter, opts) do
    start(:segmenter, Keyword.put_new(opts, :backend, VisionCore.Segmentation.Backend.Qnn))
  end

  def start(:segmenter, opts) do
    id = Pipelines.server(VisionCore.Segmentation.Supervisor, VisionCore.Segmentation.name!(opts))

    # Its own budget, and restarted by VisionCore.Reviver alone once it gives up, as a detector.
    [
      Supervisor.child_spec({VisionCore.Segmentation.Supervisor, opts},
        id: id,
        restart: :transient
      )
    ]
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
    # Restarted by VisionCore.Reviver alone once it gives up, so a crashing unit cannot exhaust the vision core's budget.
    [Supervisor.child_spec({VisionCore.Stereo.Supervisor, opts}, restart: :transient)]
  end
end
