defmodule VisionCore.Camera.Parameters do
  @moduledoc """
  The runtime controls of a camera driver as vision parameters
  (`VisionCore.Parameters`): each control of its
  `c:VisionCore.Camera.control_specs/0`, set through
  `c:VisionCore.Camera.set_controls/2` and read from
  `c:VisionCore.Camera.controls/1`.

  A control an automatic mode of the driver sets is set by that mode
  while it is on (`applies: {:auto, mode}`): `exposure_us` and
  `analogue_gain` by `auto_exposure`, and then read what the sensor
  applies (`c:VisionCore.Camera.live/1`), their defaults the manual
  settings; `red_gain` and `blue_gain` by `awb`. A driver without the
  mode among its controls has the control live.

  Started for a camera of its own (`VisionCore.Camera.Unit`), it declares
  the camera's group, `<name>.camera`, a component of the pipeline
  `<name>`: its controls, then the settings fixed at start. The stereo
  unit's cameras are declared by `VisionCore.Stereo.Parameters`, from
  `controls/3`.

  Declares nothing when the registry is not running.
  """
  use GenServer

  alias VisionCore.Parameters.Check
  alias VisionCore.Stereo

  # After the stereo pipeline's steps and before the inference pipelines'.
  @position 50
  @automatic_modes %{
    exposure_us: :auto_exposure,
    analogue_gain: :auto_exposure,
    red_gain: :awb,
    blue_gain: :awb
  }
  @explanation "The camera's capture settings. Exposure and gain set the brightness: a longer " <>
                 "exposure brightens the image but blurs what moves, and a higher gain " <>
                 "brightens it but adds noise. Auto exposure chooses them for the scene, and " <>
                 "the automatic white balance the colour gains; switch either off to set " <>
                 "them yourself. The settings fixed in the build are listed after them."

  @doc """
  Declares the camera's group. Options: `:name`, the camera's; `:driver`,
  its `VisionCore.Camera`; and `:fixed` (`[]`), its settings fixed at
  start, by name.
  """
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl GenServer
  def init(opts) do
    if Process.whereis(VisionCore.Parameters),
      do: :ok = VisionCore.Parameters.declare([group(opts)])

    {:ok, nil}
  end

  @doc "The camera's group declaration for `opts`; see `start_link/1`."
  @spec group(keyword()) :: VisionCore.Parameters.group_declaration()
  def group(opts) do
    name = Keyword.fetch!(opts, :name)
    driver = Keyword.fetch!(opts, :driver)
    id = "#{name}.camera"

    %{
      id: id,
      name: "Camera",
      summary: "Capture settings of the camera #{name}.",
      explanation: @explanation,
      kind: :component,
      pipeline: name,
      position: @position,
      parameters:
        controls(driver, driver.name_for(Atom.to_string(name)), id) ++
          Enum.map(Keyword.get(opts, :fixed, []), &Stereo.Parameters.build_parameter/1)
    }
  end

  @doc """
  The declarations of `driver`'s controls, as the camera registered as
  `server` holds them, for the group `group_id`.
  """
  @spec controls(module(), GenServer.server(), String.t()) ::
          [VisionCore.Parameters.declaration()]
  def controls(driver, server, group_id) do
    specs = driver.control_specs()
    keys = Enum.map(specs, & &1.key)
    manual = driver.controls(server)

    Enum.map(specs, fn spec ->
      mode = automatic_mode(spec.key, keys)

      %{
        name: Atom.to_string(spec.key),
        type: spec.type,
        get: control_get(spec.key, mode, driver, server),
        set: &set_result(driver.set_controls(server, [{spec.key, &1}])),
        constraint: constraint(spec),
        applies: applies(mode, group_id),
        description: spec.description
      }
      |> put_manual_default(mode, manual[spec.key])
    end)
  end

  defp automatic_mode(key, keys) do
    mode = @automatic_modes[key]
    if mode in keys, do: mode
  end

  defp applies(nil, _group_id), do: :live
  defp applies(mode, group_id), do: {:auto, "#{group_id}.#{mode}"}

  # An automatic mode's first values are not the built-in ones: the manual settings are.
  defp put_manual_default(declaration, nil, _manual), do: declaration
  defp put_manual_default(declaration, _mode, nil), do: declaration
  defp put_manual_default(declaration, _mode, manual), do: Map.put(declaration, :default, manual)

  defp control_get(key, :auto_exposure, driver, server) do
    fn ->
      controls = driver.controls(server)
      applied = controls.auto_exposure && live(driver, server)
      if applied, do: applied[live_key(key)] || controls[key], else: controls[key]
    end
  end

  defp control_get(key, _mode, driver, server), do: fn -> driver.controls(server)[key] end

  defp live(driver, server) do
    if function_exported?(driver, :live, 1), do: driver.live(server)
  end

  defp live_key(:exposure_us), do: :exposure_time_us
  defp live_key(:analogue_gain), do: :analogue_gain

  defp constraint(%{key: :rotation}), do: %{kind: :choices, values: [0, 180]}
  defp constraint(spec), do: Check.constraint(spec)

  defp set_result({:ok, _controls}), do: :ok
  defp set_result({:error, _reason} = error), do: error
end
