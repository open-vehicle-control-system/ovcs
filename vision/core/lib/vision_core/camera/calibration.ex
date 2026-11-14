defmodule VisionCore.Camera.Calibration do
  @moduledoc """
  Reads and writes the calibration of a camera of its own
  (`VisionCore.Camera.Unit`), for the dashboard.

  With a `:calibration_store_dir`, a calibration committed goes to the
  store and is the one in force; the camera's `:calibration` holds the
  built-in one, which `reset/2` goes back to. Without a store, a commit
  writes the `:calibration` path itself. The file is written whole or
  not at all, through a temporary file synced then renamed over it.
  Commits and resets of one camera run one at a time.

  Each commit or reset is published as `{:camera_calibration_changed,
  name}` under `changed_key/1`. The camera's consumers read the
  calibration when they start; the ROS 2 exporter reads its camera info
  again at each change.
  """
  require Logger

  alias VisionCore.Camera.{StoredFile, Unit}
  alias VisionCore.Outputs
  alias VisionCore.Ros2.CameraCalibration

  @type camera :: %{
          path: Path.t() | nil,
          calibration: CameraCalibration.t() | nil,
          yaml: String.t() | nil
        }

  @type in_use :: %{
          source: :stored | :built_in | :none,
          stored_at: DateTime.t() | nil,
          can_reset: boolean(),
          camera: camera(),
          error: String.t() | nil
        }

  @doc "The `VisionCore.Outputs` key a change of the calibration of the camera `name` is published under."
  @spec changed_key(atom()) :: {:camera_calibration, atom()}
  def changed_key(name), do: {:camera_calibration, name}

  @doc """
  The calibration in force for the camera `name` of `config`, the active
  `VisionCore.Config`: its path, parsed calibration and YAML (`nil`
  without a file), and its source. `stored_at` is the time the stored
  file was written, and `can_reset` whether one is stored with a built-in
  calibration to go back to. A file that cannot be read, or whose matrices
  have not their count of values, gives no calibration, and `error` says
  why, which is logged. `{:error, :not_found}` for a camera `config` has
  not.
  """
  @spec in_use(VisionCore.Config.t(), atom()) :: {:ok, in_use()} | {:error, :not_found}
  def in_use(config, name) do
    with {:ok, settings} <- settings(config, name) do
      {camera, error} = read(settings.calibration_path)
      if error, do: Logger.warning("#{__MODULE__}[#{name}] #{error}")
      stored? = stored?(settings)

      {:ok,
       %{
         source: source(camera, stored?),
         stored_at: if(stored?, do: StoredFile.written_at(settings.calibration_store_path)),
         can_reset: stored? and built_in?(settings),
         camera: camera,
         error: error
       }}
    end
  end

  @doc """
  Writes `calibration` as the camera `name`'s, to its store when it has
  one, else to its calibration path.
  """
  @spec commit(VisionCore.Config.t(), atom(), CameraCalibration.t()) ::
          :ok | {:error, :not_found | String.t()}
  def commit(config, name, %CameraCalibration{} = calibration) do
    with {:ok, settings} <- settings(config, name),
         {:ok, path} <- writable_path(settings) do
      yaml = CameraCalibration.to_yaml(calibration, Atom.to_string(name))

      locked(name, fn ->
        with :ok <- StoredFile.write(path, yaml, __MODULE__), do: changed(name)
      end)
    end
  end

  @doc "Removes the camera `name`'s stored calibration, so that its built-in one is in force again."
  @spec reset(VisionCore.Config.t(), atom()) :: :ok | {:error, :not_found | String.t()}
  def reset(config, name) do
    with {:ok, settings} <- settings(config, name) do
      locked(name, fn ->
        with :ok <- check_resettable(settings),
             :ok <- StoredFile.remove(settings.calibration_store_path, __MODULE__),
             do: changed(name)
      end)
    end
  end

  # The lock is local to the node, as the files are.
  defp locked(name, fun), do: :global.trans({{__MODULE__, name}, self()}, fun, [node()])

  defp settings(config, name) do
    case Enum.find(Unit.settings(config), &(&1.name == name)) do
      nil -> {:error, :not_found}
      settings -> {:ok, settings}
    end
  end

  # The camera, and why its file gives no calibration, `nil` when it does or there is no file.
  defp read(nil), do: {%{path: nil, calibration: nil, yaml: nil}, nil}

  defp read(path) do
    case File.read(path) do
      {:ok, yaml} ->
        parse(path, yaml)

      {:error, :enoent} ->
        {%{path: path, calibration: nil, yaml: nil}, nil}

      {:error, reason} ->
        {%{path: path, calibration: nil, yaml: nil},
         "cannot read #{path}: #{StoredFile.file_error(reason)}"}
    end
  end

  defp parse(path, yaml) do
    case CameraCalibration.parse(yaml) do
      {:ok, calibration} -> {%{path: path, calibration: calibration, yaml: yaml}, nil}
      {:error, message} -> {%{path: path, calibration: nil, yaml: yaml}, "#{path}: #{message}"}
    end
  end

  defp source(%{calibration: nil}, _stored?), do: :none
  defp source(_camera, true), do: :stored
  defp source(_camera, false), do: :built_in

  defp stored?(%{calibration_store_path: nil}), do: false
  defp stored?(%{calibration_store_path: path}), do: File.exists?(path)

  defp built_in?(%{built_in_calibration_path: nil}), do: false
  defp built_in?(%{built_in_calibration_path: path}), do: File.exists?(path)

  defp writable_path(settings) do
    case settings.calibration_store_path || settings.built_in_calibration_path do
      nil -> {:error, "the camera has no calibration path to write"}
      path -> {:ok, path}
    end
  end

  defp check_resettable(%{calibration_store_path: nil}),
    do: {:error, "the camera has no calibration store"}

  defp check_resettable(settings) do
    cond do
      not stored?(settings) -> {:error, "nothing is stored"}
      not built_in?(settings) -> {:error, "there is no built-in calibration to return to"}
      true -> :ok
    end
  end

  defp changed(name), do: Outputs.publish(changed_key(name), {:camera_calibration_changed, name})
end
