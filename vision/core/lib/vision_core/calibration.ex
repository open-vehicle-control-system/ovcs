defmodule VisionCore.Calibration do
  @moduledoc """
  What the unit can calibrate: its stereo pair, identified by the stereo
  unit's prefix, and each camera of its own that sends an image output,
  identified by its name. The dashboard reads the calibration in use of
  each target and returns it to its built-in one here; a
  `VisionCore.Calibration.Session` calibrates one of them.

  The stereo pair's files are `VisionCore.Stereo.Calibration`'s, a
  camera's `VisionCore.Camera.Calibration`'s.
  """

  alias VisionCore.Camera.Calibration, as: OwnCalibration
  alias VisionCore.Camera.Unit
  alias VisionCore.Outputs
  alias VisionCore.Ros2.CameraCalibration
  alias VisionCore.Stereo.Calibration, as: StereoCalibration
  alias VisionCore.Stereo.Supervisor, as: StereoSupervisor

  @sides [:left, :right]

  @typedoc """
  A calibration target: its `id`, its `kind`, a camera's `name`, the
  labels of the frames its cameras send, the `VisionCore.Outputs` keys
  those frames are published under and the names its cameras register
  under.
  """
  @type target :: %{
          id: String.t(),
          kind: :stereo | :camera,
          name: atom() | nil,
          labels: [String.t()],
          frame_keys: [Outputs.key()],
          servers: [atom()]
        }

  @type camera :: %{
          name: String.t(),
          file: String.t(),
          path: Path.t() | nil,
          calibration: CameraCalibration.t() | nil,
          yaml: String.t() | nil
        }

  @typedoc """
  The calibration in use of a target: where it comes from, when a stored
  one was written, whether it can go back to a built-in one, each
  camera's calibration with the file name to save it under, for a
  stereo pair its rectified baseline, and why a file gives no
  calibration, `nil` when each does or is absent.
  """
  @type in_use :: %{
          id: String.t(),
          kind: :stereo | :camera,
          source: :stored | :built_in | :none,
          stored_at: DateTime.t() | nil,
          can_reset: boolean(),
          cameras: [camera()],
          baseline_m: float() | nil,
          error: String.t() | nil
        }

  @doc "The targets of `config`, the active `VisionCore.Config`: its stereo pair first, then its cameras in config order."
  @spec targets(VisionCore.Config.t()) :: [target()]
  def targets(%VisionCore.Config{} = config), do: stereo_targets(config) ++ camera_targets(config)

  @doc "The target `id` of `config`, or `:error`."
  @spec fetch_target(VisionCore.Config.t(), String.t()) :: {:ok, target()} | :error
  def fetch_target(config, id) do
    case Enum.find(targets(config), &(&1.id == id)) do
      nil -> :error
      target -> {:ok, target}
    end
  end

  @doc "The `VisionCore.Outputs` key a change of `target`'s calibration is published under."
  @spec changed_key(target()) :: Outputs.key()
  def changed_key(%{kind: :stereo, id: prefix}), do: StereoCalibration.changed_key(prefix)
  def changed_key(%{kind: :camera, name: name}), do: OwnCalibration.changed_key(name)

  @doc "The calibration in use of the target `id` of `config`; `{:error, :not_found}` for an id that is none of its targets."
  @spec in_use(VisionCore.Config.t(), String.t()) ::
          {:ok, in_use()} | {:error, :not_found | String.t()}
  def in_use(config, id) do
    with {:ok, target} <- fetch(config, id), do: target_in_use(config, target)
  end

  @doc """
  Returns the target `id` of `config` to its built-in calibration. `opts`
  are `VisionCore.Stereo.Calibration.reset/2`'s, for a stereo pair.
  """
  @spec reset(VisionCore.Config.t(), String.t(), keyword()) ::
          :ok | {:error, :not_found | String.t()}
  def reset(config, id, opts \\ []) do
    case fetch(config, id) do
      {:ok, %{kind: :stereo}} -> StereoCalibration.reset(config, opts)
      {:ok, %{kind: :camera, name: name}} -> OwnCalibration.reset(config, name)
      {:error, :not_found} -> {:error, :not_found}
    end
  end

  defp fetch(config, id) do
    case fetch_target(config, id) do
      {:ok, target} -> {:ok, target}
      :error -> {:error, :not_found}
    end
  end

  defp stereo_targets(config) do
    case StereoSupervisor.camera_options(config) do
      {:ok, cameras} ->
        [
          %{
            id: cameras[:prefix],
            kind: :stereo,
            name: nil,
            labels: Enum.map(@sides, &Atom.to_string/1),
            frame_keys:
              for({{:camera_frame, _side}, key} <- StereoSupervisor.outputs(config), do: key),
            servers: for({_driver, server} <- StereoSupervisor.cameras(config), do: server)
          }
        ]

      {:error, _reason} ->
        []
    end
  end

  defp camera_targets(config) do
    for settings <- Unit.settings(config),
        key = Unit.output_key(config, settings.name, nil) do
      label = Atom.to_string(settings.name)

      %{
        id: label,
        kind: :camera,
        name: settings.name,
        labels: [label],
        frame_keys: [key],
        servers: [settings.server]
      }
    end
  end

  defp target_in_use(config, %{kind: :stereo, id: prefix}) do
    with {:ok, in_use} <- StereoCalibration.in_use(config) do
      cameras =
        for side <- @sides,
            do: camera(Atom.to_string(side), "#{prefix}_#{side}.yaml", in_use[side])

      {:ok,
       %{
         id: prefix,
         kind: :stereo,
         source: in_use.source,
         stored_at: in_use.stored_at,
         can_reset: in_use.can_reset,
         cameras: cameras,
         baseline_m: in_use.baseline_m,
         error: in_use.error
       }}
    end
  end

  defp target_in_use(config, %{kind: :camera, id: id, name: name}) do
    with {:ok, in_use} <- OwnCalibration.in_use(config, name) do
      {:ok,
       %{
         id: id,
         kind: :camera,
         source: in_use.source,
         stored_at: in_use.stored_at,
         can_reset: in_use.can_reset,
         cameras: [camera(id, "#{id}.yaml", in_use.camera)],
         baseline_m: nil,
         error: in_use.error
       }}
    end
  end

  defp camera(name, file, %{path: path, calibration: calibration, yaml: yaml}),
    do: %{name: name, file: file, path: path, calibration: calibration, yaml: yaml}
end
