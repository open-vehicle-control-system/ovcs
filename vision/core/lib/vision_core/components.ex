defmodule VisionCore.Components do
  @moduledoc """
  Resolves the symbolic entries of `VisionCore.Config.components` into
  supervised child specs.

  Each clause of `start/2` returns the child specs of one component. The
  runtime shape is exactly what the vehicle declared; there are no
  implicit defaults.

  The components produce the unit's outputs; what takes them out of the
  unit, such as `VisionCore.Ros2.ZenohExporter`, is an exporter
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
    * `:hailo_detector` — `:detector` with the Hailo backend
      (`VisionCore.Detection.Backend.Hailo`), on the Hailo-8.
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
    * `:hailo_segmenter` — `:segmenter` with the Hailo backend
      (`VisionCore.Segmentation.Backend.Hailo`), on the Hailo-8. Every
      `:hailo_detector` and `:hailo_segmenter` shares the accelerator
      through `VisionCore.Hailo` (`hailo_children/1`).
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
      driver's (`VisionCore.Camera.Unit`). With `driver:
      VisionCore.Camera.LibCameraStream` and `stream_of: side`, the
      camera is a second stream of the stereo unit's `side` camera,
      which `wire_streams!/1` connects.
  """

  alias VisionCore.{Detection, Pipelines}
  alias VisionCore.Camera.{LibCamera, LibCameraStream}

  @doc """
  The child that runs `components`' Hailo networks, before their units:
  `VisionCore.Hailo`, under a supervisor of its own budget, with each
  `:hailo_detector`'s and `:hailo_segmenter`'s model as its pipeline's
  network, in `components`' order, and the Port's options from the
  first unit that gives each. `[]` without such a component.
  """
  @spec hailo_children([atom() | {atom(), keyword()}]) :: [Supervisor.child_spec()]
  def hailo_children(components) do
    units =
      for component <- components,
          {kind, opts} = if(is_atom(component), do: {component, []}, else: component),
          kind in [:hailo_detector, :hailo_segmenter],
          do: {kind, opts}

    if units == [] do
      []
    else
      networks = Enum.map(units, &hailo_network/1)

      port_options =
        units
        |> Enum.flat_map(fn {_kind, opts} ->
          Keyword.take(opts, VisionCore.Hailo.port_options())
        end)
        |> Enum.uniq_by(&elem(&1, 0))

      [
        # Not restarted once it gives up, as a unit: VisionCore.Reviver starts it again.
        Supervisor.child_spec(
          {VisionCore.Hailo.Supervisor, [networks: networks] ++ port_options},
          id: VisionCore.Hailo.Supervisor,
          restart: :transient
        )
      ]
    end
  end

  defp hailo_network({:hailo_detector, opts}),
    do:
      {Detection.pipeline_name(opts),
       [kind: :detection] ++ Keyword.take(opts, [:hef_path, :score_threshold])}

  defp hailo_network({:hailo_segmenter, opts}),
    do:
      {Keyword.get(opts, :name),
       [
         kind: :segmentation,
         classes: length(Keyword.get(opts, :labels, VisionCore.Segmentation.labels()))
       ] ++ Keyword.take(opts, [:hef_path, :cell_pixels])}

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

  def start(:hailo_segmenter, opts) do
    start(:segmenter, Keyword.put_new(opts, :backend, VisionCore.Segmentation.Backend.Hailo))
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

  @doc """
  `components` with each camera of its own made from a stereo side's
  stream (`VisionCore.Camera.LibCameraStream`, `stream_of: side`) wired
  to that side: the side's options in the `:stereo` component take the
  camera's `:outputs` and `:max_hz` as `:outputs` and `:outputs_max_hz`,
  which `VisionCore.Camera.LibCamera` makes, and the camera takes the
  side's label as `:side_label`. `components` as they are without such a
  camera. Pure.

  Raises `ArgumentError`, naming the camera, for a `stream_of:` without a
  `:stereo` component or on one whose driver is not
  `VisionCore.Camera.LibCamera`, a `stream_of:` other than `:left` or
  `:right`, on another driver or missing on a `LibCameraStream` camera,
  a side two cameras name, a camera without outputs, and outputs the
  side cannot make (`VisionCore.Camera.LibCamera.capture_outputs/1`),
  such as an ISP output of an odd size or larger than the side's
  `:sensor_mode`. The vision core then fails to start, before any
  capture opens.
  """
  @spec wire_streams!(list()) :: list()
  def wire_streams!(components) do
    case stream_cameras(components) do
      [] -> components
      cameras -> wire!(components, cameras)
    end
  end

  defp stream_cameras(components) do
    for {:camera, opts} <- components,
        is_list(opts),
        opts[:driver] == LibCameraStream or Keyword.has_key?(opts, :stream_of),
        do: check_stream_camera!(opts)
  end

  defp check_stream_camera!(opts) do
    who = "camera #{inspect(opts[:name])}"

    cond do
      opts[:driver] != LibCameraStream ->
        raise ArgumentError,
              "#{who}: stream_of: is #{inspect(LibCameraStream)}'s, " <>
                "and its driver is #{inspect(opts[:driver])}"

      not Keyword.has_key?(opts, :stream_of) ->
        raise ArgumentError,
              "#{who}: #{inspect(LibCameraStream)} needs stream_of:, " <>
                "the stereo side whose capture makes it"

      opts[:stream_of] not in [:left, :right] ->
        raise ArgumentError,
              "#{who}: stream_of: is :left or :right, the stereo side whose capture makes it, " <>
                "got #{inspect(opts[:stream_of])}"

      true ->
        opts
    end
  end

  defp wire!(components, cameras) do
    check_sides_once!(cameras)
    stereo = stereo_options!(components, hd(cameras))
    labels = VisionCore.Stereo.Supervisor.labels(%VisionCore.Config{components: components})
    by_name = Map.new(cameras, &{&1[:name], &1})

    Enum.map(components, fn
      {:stereo, ^stereo} ->
        {:stereo, Enum.reduce(cameras, stereo, &give_side_outputs!/2)}

      {:camera, opts} = component when is_list(opts) ->
        if Map.get(by_name, opts[:name]) == opts,
          do: {:camera, Keyword.put(opts, :side_label, Keyword.fetch!(labels, opts[:stream_of]))},
          else: component

      component ->
        component
    end)
  end

  defp check_sides_once!(cameras) do
    cameras
    |> Enum.group_by(& &1[:stream_of], & &1[:name])
    |> Enum.find(fn {_side, names} -> length(names) > 1 end)
    |> case do
      nil ->
        :ok

      {side, [first, second | _others]} ->
        raise ArgumentError,
              "cameras #{inspect(first)} and #{inspect(second)} both name " <>
                "stream_of: #{inspect(side)}: the ISP makes one stream beside the frames' own"
    end
  end

  defp stereo_options!(components, camera) do
    who = "camera #{inspect(camera[:name])}"

    case for({:stereo, opts} <- components, is_list(opts), do: opts) do
      [] ->
        raise ArgumentError,
              "#{who}: stream_of: #{inspect(camera[:stream_of])} names a side of the stereo " <>
                "unit, and there is no :stereo component"

      [opts | _others] ->
        if opts[:driver] == LibCamera,
          do: opts,
          else:
            raise(
              ArgumentError,
              "#{who}: stream_of: is a second stream of a #{inspect(LibCamera)} capture, " <>
                "and the stereo unit's driver is #{inspect(opts[:driver])}"
            )
    end
  end

  defp give_side_outputs!(camera, stereo) do
    side = camera[:stream_of]
    who = "camera #{inspect(camera[:name])}"

    with {:error, message} <- LibCameraStream.outputs(camera),
         do: raise(ArgumentError, "#{who}: #{message}")

    side_opts =
      Keyword.get(stereo, side, []) ++
        [outputs: camera[:outputs]] ++
        if(Keyword.has_key?(camera, :max_hz), do: [outputs_max_hz: camera[:max_hz]], else: [])

    case LibCamera.capture_outputs(side_opts) do
      {:ok, _outputs} ->
        Keyword.update(stereo, side, side_opts, fn _side_opts -> side_opts end)

      {:error, message} ->
        raise ArgumentError,
              "#{who}, made by the stereo unit's #{side} camera as its :outputs and " <>
                ":outputs_max_hz (the camera's max_hz): #{message}"
    end
  end
end
