defmodule VisionCore.Camera.Unit do
  @moduledoc """
  Supervises a camera of its own, outside the stereo pair: one
  `VisionCore.Camera` driver, which the `:camera` component
  (`VisionCore.Components`) starts with its options.

  `:name` names the camera. It follows the rule of a detection
  pipeline's name (`VisionCore.Pipelines.name?/1`), whose reserved names
  include `:left` and `:right`, so no camera takes a stereo side's name;
  and no camera shares a detection pipeline's name, since both publish
  under `<prefix>/<name>/` (`VisionCore.Application` refuses both, and
  two cameras of one name). `:driver` is the driver's module. The driver
  is started with the other options, `:label`, the name's text, which
  its frames carry, and `:frame_id`, `"<name>_optical"` unless the camera
  sets one: `VisionCore.Camera.V4L2Single` on a CAMSS board,
  `VisionCore.Camera.GStreamer` for a USB camera on a workstation.

  A driver with named outputs (`c:VisionCore.Camera.outputs/1`), such as
  `VisionCore.Camera.V4L2Single`, makes each of the camera's `:outputs`
  at every frame (`VisionCore.Camera.Output`), and publishes each it sends
  under a key of its own (`output_key/3`); an output with `send: false`
  has none. A consumer takes the output it names, or the camera's first
  sent image output, its default: the pipelines on a camera source
  (`source: {:camera, name, output}`), the exporters (`{:camera_frame,
  name, output}`), the preview and the pose capture. Each refuses an
  output the camera does not send (`unsent_output?/3`). An H.264 output
  is a video, whose key only a consumer of videos takes
  (`video_key/3`): the exporters (`{:camera_video, name, output}`) and
  the dashboard's video relay (`VisionCore.Video`). Outputs the driver
  cannot make, or `:outputs` given to a driver without named outputs,
  stop the unit at start, saying why.

  Three options describe the camera to its consumers, such as
  `VisionCore.Ros2.Exporter`, and are not given to the driver
  (`settings/1`):

    * `:calibration` — its `camera_info` YAML
      (`VisionCore.Ros2.CameraCalibration`): K and D.
    * `:calibration_store_dir` — a writable directory for a calibration
      committed at runtime (`set_camera_info`), as `camera_<name>.yaml`,
      apart from the stereo unit's `<prefix>_<side>.yaml` in a directory
      they share. Once stored there it takes precedence over
      `:calibration`, as the stereo unit's (`VisionCore.Stereo.Supervisor`).
    * `:pose` — its pose relative to the stereo pair, a YAML
      `VisionCore.Camera.Pose` reads.

  Exists to contain failure, as `VisionCore.Detection.Supervisor` does:
  a driver that keeps crashing is restarted within this supervisor's own
  budget, then the unit stops and, a `:transient` child, stays down,
  while the stereo unit and the rest of the vision core run on. A
  component whose `:name` or `:driver` is invalid raises `ArgumentError`
  as it starts. A unit that fails to start, such as one whose driver
  cannot, is left down with the reason logged.
  """
  use Supervisor

  alias VisionCore.Camera.Output
  alias VisionCore.Pipelines

  # Its own budget, so a crash loop stops here instead of in the vision core supervisor.
  @max_restarts 10
  @max_seconds 60

  @consumer_options [:calibration, :calibration_store_dir, :pose]

  @typedoc "What a camera's consumers read of it; see `settings/1`."
  @type settings :: %{
          name: atom(),
          server: atom(),
          frame_id: String.t(),
          calibration_path: Path.t() | nil,
          calibration_store_path: Path.t() | nil,
          pose_path: Path.t() | nil,
          outputs: [Output.t()]
        }

  @doc """
  The camera's name in the `:camera` component's `opts`. Raises
  `ArgumentError` when `opts` have no valid `:name`, or no `:driver`
  that is a `VisionCore.Camera`.
  """
  @spec name!(keyword()) :: atom()
  def name!(opts) do
    name =
      case Keyword.fetch(opts, :name) do
        {:ok, name} -> Pipelines.name!(name, "a camera")
        :error -> raise ArgumentError, "a :camera component needs a :name"
      end

    driver =
      Keyword.get_lazy(opts, :driver, fn ->
        raise ArgumentError, "a :camera component needs a :driver, its VisionCore.Camera"
      end)

    unless camera_driver?(driver),
      do: raise(ArgumentError, "its :driver, #{inspect(driver)}, is not a VisionCore.Camera")

    name
  end

  @doc """
  Starts the camera unit; see the module doc for `opts`. `:ignore` when
  it fails to start, so the vision core starts without it.
  """
  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)

    VisionCore.Unit.start_contained(__MODULE__, opts, [], "camera #{inspect(name)}")
  end

  @impl Supervisor
  def init(opts) do
    name = name!(opts)
    {driver, driver_opts} = Keyword.pop!(opts, :driver)

    with {:error, message} <- named_outputs(driver, driver_opts),
         do: raise(ArgumentError, "camera #{name}: #{message}")

    driver_opts =
      driver_opts
      |> Keyword.drop(@consumer_options)
      |> Keyword.put_new(:frame_id, default_frame_id(name))
      |> Keyword.put(:label, Atom.to_string(name))

    Supervisor.init([{driver, driver_opts}],
      strategy: :one_for_one,
      max_restarts: @max_restarts,
      max_seconds: @max_seconds
    )
  end

  @doc """
  The cameras of `config`'s `:camera` components, in config order: each
  name, driver module and the name the driver registers the camera
  under. A component whose name is not valid, or whose driver is not a
  `VisionCore.Camera`, is left out.
  """
  @spec cameras(VisionCore.Config.t()) :: [{name :: atom(), driver :: module(), server :: atom()}]
  def cameras(%VisionCore.Config{components: components}) do
    for {:camera, opts} <- components,
        is_list(opts),
        name = Keyword.get(opts, :name),
        Pipelines.name?(name),
        driver = Keyword.get(opts, :driver),
        camera_driver?(driver),
        do: {name, driver, driver.name_for(Atom.to_string(name))}
  end

  @doc """
  The outputs of `config`'s cameras, in config order, with their
  `VisionCore.Outputs` keys: `{:camera_frame, name}`, as
  `VisionCore.Exporter` names it, under the key of the camera's default
  output (`output_key/3`), one per camera; a camera whose outputs cannot
  be made has none.
  """
  @spec outputs(VisionCore.Config.t()) :: [
          {VisionCore.Exporter.output(), VisionCore.Outputs.key()}
        ]
  def outputs(config) do
    for {name, _driver, _server} <- cameras(config),
        key = output_key(config, name, nil),
        do: {{:camera_frame, name}, key}
  end

  @doc """
  The named outputs of `config`'s camera `name`: `{:ok, outputs}`,
  `{:ok, nil}` for a driver without named outputs, `{:error, message}`
  for outputs it cannot make, and `:error` when `config` has no camera
  `name`.
  """
  @spec camera_outputs(VisionCore.Config.t(), atom()) ::
          {:ok, [Output.t()] | nil} | {:error, String.t()} | :error
  def camera_outputs(config, name) do
    case List.keyfind(cameras(config), name, 0) do
      {^name, driver, _server} -> named_outputs(driver, camera_options(config, name))
      nil -> :error
    end
  end

  @doc """
  The `VisionCore.Outputs` key the frames of the camera `name`'s image
  output `output` are published under in `config`, its default output's,
  its first sent image output, with `output` `nil`: `{:camera_frame,
  server, output}` for a driver with named outputs, `{:camera_frame,
  server}` for one without, which has only its default. `nil` when
  `config` has no such camera or output, the camera does not send that
  output, or it is a video (`video_key/3`).
  """
  @spec output_key(VisionCore.Config.t(), atom(), atom() | nil) :: VisionCore.Outputs.key() | nil
  def output_key(config, name, output) do
    with {^name, _driver, server} <- List.keyfind(cameras(config), name, 0),
         {:ok, outputs} <- camera_outputs(config, name) do
      case {outputs, output} do
        {nil, nil} -> {:camera_frame, server}
        {nil, _named} -> nil
        {outputs, output} -> sent_output_key(server, Output.images(outputs), output)
      end
    else
      _no_camera_or_outputs -> nil
    end
  end

  @doc """
  The `VisionCore.Outputs` key the frames of the camera `name`'s H.264
  output `output` are published under in `config`, `{:camera_frame,
  server, output}`; `nil` when `config` has no such camera or output, or
  the output is an image.
  """
  @spec video_key(VisionCore.Config.t(), atom(), atom()) :: VisionCore.Outputs.key() | nil
  def video_key(config, name, output) do
    with {^name, _driver, server} <- List.keyfind(cameras(config), name, 0),
         {:ok, outputs} when is_list(outputs) <- camera_outputs(config, name),
         true <- Enum.any?(Output.videos(outputs), &(&1.name == output)) do
      {:camera_frame, server, output}
    else
      _no_such_video -> nil
    end
  end

  @doc "Whether `output` is an H.264 output of `config`'s camera `name`, a video, not an image."
  @spec video_output?(VisionCore.Config.t(), atom(), atom() | nil) :: boolean()
  def video_output?(config, name, output), do: video_key(config, name, output) != nil

  defp sent_output_key(server, [default | _others], nil),
    do: {:camera_frame, server, default.name}

  defp sent_output_key(server, sent, output),
    do: if(Enum.any?(sent, &(&1.name == output)), do: {:camera_frame, server, output})

  @doc """
  Whether `output` is an output of `config`'s camera `name` made only
  for the outputs made from it, with `send: false`, which no consumer
  can take.
  """
  @spec unsent_output?(VisionCore.Config.t(), atom(), atom() | nil) :: boolean()
  def unsent_output?(config, name, output) do
    case camera_outputs(config, name) do
      {:ok, outputs} when is_list(outputs) ->
        Enum.any?(outputs, &(&1.name == output and not &1.send))

      _no_named_outputs ->
        false
    end
  end

  # `{:ok, nil}` for a driver without named outputs, which takes no `:outputs`.
  defp named_outputs(driver, opts) do
    cond do
      function_exported?(driver, :outputs, 1) ->
        driver.outputs(opts)

      Keyword.has_key?(opts, :outputs) ->
        {:error, "its driver, #{inspect(driver)}, has no outputs"}

      true ->
        {:ok, nil}
    end
  end

  defp camera_options(%VisionCore.Config{components: components}, name) do
    Enum.find_value(components, [], fn
      {:camera, opts} when is_list(opts) -> if opts[:name] == name, do: opts
      _component -> nil
    end)
  end

  @doc """
  What the consumers of `config`'s cameras read of each, in config order,
  for the cameras `cameras/1` lists: its name, the name its driver
  registers under, its optical frame, its calibration path, the stored
  calibration first when there is one, the path a committed calibration
  is stored at (`nil` without a store), and its pose path. The store is
  read at each call. `:outputs` are the named image outputs it sends, in
  config order, its default first, none for a driver without them or
  whose outputs cannot be made.
  """
  @spec settings(VisionCore.Config.t()) :: [settings()]
  def settings(%VisionCore.Config{components: components} = config) do
    options = for {:camera, opts} <- components, is_list(opts), into: %{}, do: {opts[:name], opts}

    for {name, driver, server} <- cameras(config) do
      opts = Map.fetch!(options, name)
      store_path = calibration_store_path(opts[:calibration_store_dir], name)

      outputs =
        case named_outputs(driver, opts) do
          {:ok, outputs} when is_list(outputs) -> Output.images(outputs)
          _none -> []
        end

      %{
        name: name,
        server: server,
        frame_id: Keyword.get(opts, :frame_id, default_frame_id(name)),
        calibration_path: calibration_path(opts[:calibration], store_path),
        calibration_store_path: store_path,
        pose_path: opts[:pose],
        outputs: outputs
      }
    end
  end

  defp calibration_store_path(nil, _name), do: nil
  defp calibration_store_path(directory, name), do: Path.join(directory, "camera_#{name}.yaml")

  defp calibration_path(calibration, nil), do: calibration

  defp calibration_path(calibration, store_path),
    do: if(File.exists?(store_path), do: store_path, else: calibration)

  defp default_frame_id(name), do: "#{name}_optical"

  defp camera_driver?(driver),
    do:
      is_atom(driver) and Code.ensure_loaded?(driver) and function_exported?(driver, :name_for, 1)
end
