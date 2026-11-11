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

  alias VisionCore.Detection

  # Its own budget, so a crash loop stops here instead of in the vision core supervisor.
  @max_restarts 10
  @max_seconds 60

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

    driver_opts =
      driver_opts
      |> Keyword.put_new(:frame_id, "#{name}_optical")
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
  `VisionCore.Exporter` names it, under `{:camera_frame, server}`.
  """
  @spec outputs(VisionCore.Config.t()) :: [
          {VisionCore.Exporter.output(), VisionCore.Outputs.key()}
        ]
  def outputs(config) do
    for {name, _driver, server} <- cameras(config),
        do: {{:camera_frame, name}, {:camera_frame, server}}
  end

  defp camera_driver?(driver),
    do:
      is_atom(driver) and Code.ensure_loaded?(driver) and function_exported?(driver, :name_for, 1)
end
