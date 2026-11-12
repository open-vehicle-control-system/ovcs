defmodule VisionCore.Camera.Unit do
  @moduledoc """
  Supervises a camera of its own, outside the stereo pair: one
  `VisionCore.Camera` driver, which the `:camera` component
  (`VisionCore.Components`) starts with its options.

  `:name` names the camera. It follows the rule of a detection
  pipeline's name (`VisionCore.Detection.name?/1`), whose reserved names
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
  at every frame (`VisionCore.Camera.Output`), published each under a key
  of its own (`output_key/3`). A consumer takes the output it names, or
  the camera's first, its default: the pipelines on a camera source
  (`source: {:camera, name, output}`), the exporters (`{:camera_frame,
  name, output}`), the preview and the pose capture. Outputs the driver
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
  require Logger

  alias VisionCore.Camera.Output
  alias VisionCore.Detection

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
        {:ok, name} -> Detection.name!(name, "a camera")
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

    case Supervisor.start_link(__MODULE__, opts) do
      {:error, reason} ->
        Logger.error(
          "#{inspect(__MODULE__)} failed to start, camera #{inspect(name)} down: " <>
            failure_text(reason)
        )

        :ignore

      started ->
        started
    end
  end

  defp failure_text({:shutdown, {:failed_to_start_child, _child, reason}}),
    do: failure_text(reason)

  defp failure_text({%{__exception__: true} = exception, _stacktrace}),
    do: Exception.message(exception)

  defp failure_text(reason) when is_binary(reason), do: reason
  defp failure_text(reason), do: inspect(reason)

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
        Detection.name?(name),
        driver = Keyword.get(opts, :driver),
        camera_driver?(driver),
        do: {name, driver, driver.name_for(Atom.to_string(name))}
  end

  @doc """
  The outputs of `config`'s cameras, in config order, with their
  `VisionCore.Outputs` keys: `{:camera_frame, name}`, as
  `VisionCore.Exporter` names it, under the key of the camera's default
  output (`output_key/3`), one per camera.
  """
  @spec outputs(VisionCore.Config.t()) :: [
          {VisionCore.Exporter.output(), VisionCore.Outputs.key()}
        ]
  def outputs(config) do
    for {name, _driver, _server} <- cameras(config),
        do: {{:camera_frame, name}, output_key(config, name, nil)}
  end

  @doc """
  The `VisionCore.Outputs` key the frames of the camera `name`'s output
  `output` are published under in `config`, its default output's with
  `output` `nil`: `{:camera_frame, server, output}` for a driver with
  named outputs, `{:camera_frame, server}` for one without, which has
  only its default. `nil` when `config` has no such camera or output.
  """
  @spec output_key(VisionCore.Config.t(), atom(), atom() | nil) :: VisionCore.Outputs.key() | nil
  def output_key(config, name, output) do
    with {^name, driver, server} <- List.keyfind(cameras(config), name, 0),
         {:ok, outputs} <- named_outputs(driver, camera_options(config, name)) do
      case {outputs, output} do
        {nil, nil} ->
          {:camera_frame, server}

        {nil, _named} ->
          nil

        {[default | _others], nil} ->
          {:camera_frame, server, default.name}

        {outputs, output} ->
          if Enum.any?(outputs, &(&1.name == output)), do: {:camera_frame, server, output}
      end
    else
      _no_camera_or_outputs -> nil
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
  read at each call. `:outputs` are its named outputs, in config order,
  none for a driver without them or whose outputs cannot be made.
  """
  @spec settings(VisionCore.Config.t()) :: [settings()]
  def settings(%VisionCore.Config{components: components} = config) do
    options = for {:camera, opts} <- components, is_list(opts), into: %{}, do: {opts[:name], opts}

    for {name, driver, server} <- cameras(config) do
      opts = Map.fetch!(options, name)
      store_path = calibration_store_path(opts[:calibration_store_dir], name)

      outputs =
        case named_outputs(driver, opts) do
          {:ok, outputs} when is_list(outputs) -> outputs
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
