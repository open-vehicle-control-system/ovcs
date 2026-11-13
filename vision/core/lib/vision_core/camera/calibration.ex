defmodule VisionCore.Camera.Calibration do
  @moduledoc """
  Reads and writes the calibration of a camera of its own
  (`VisionCore.Camera.Unit`), for the dashboard.

  With a `:calibration_store_dir`, a calibration committed goes to the
  store and is the one in force; the camera's `:calibration` holds the
  built-in one, which `reset/2` goes back to. Without a store, a commit
  writes the `:calibration` path itself. The file is written whole or
  not at all, through a temporary file renamed over it.

  Each commit or reset is published as `{:camera_calibration_changed,
  name}` under `changed_key/1`. The camera's consumers read the
  calibration when they start; the ROS 2 exporter reads its camera info
  again at each change.
  """
  require Logger

  alias VisionCore.Camera.Unit
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
          camera: camera()
        }

  @doc "The `VisionCore.Outputs` key a change of the calibration of the camera `name` is published under."
  @spec changed_key(atom()) :: {:camera_calibration, atom()}
  def changed_key(name), do: {:camera_calibration, name}

  @doc """
  The calibration in force for the camera `name` of `config`, the active
  `VisionCore.Config`: its path, parsed calibration and YAML (`nil`
  without a file), and its source. `stored_at` is the time the stored
  file was written, and `can_reset` whether one is stored with a built-in
  calibration to go back to. `{:error, :not_found}` for a camera `config`
  has not.
  """
  @spec in_use(VisionCore.Config.t(), atom()) ::
          {:ok, in_use()} | {:error, :not_found | String.t()}
  def in_use(config, name) do
    with {:ok, settings} <- settings(config, name),
         {:ok, camera} <- read(settings.calibration_path) do
      stored? = stored?(settings)

      {:ok,
       %{
         source: source(camera, stored?),
         stored_at: if(stored?, do: written_at(settings.calibration_store_path)),
         can_reset: stored? and built_in?(settings),
         camera: camera
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
         {:ok, path} <- writable_path(settings),
         :ok <- write(path, CameraCalibration.to_yaml(calibration, Atom.to_string(name))) do
      changed(name)
    end
  end

  @doc "Removes the camera `name`'s stored calibration, so that its built-in one is in force again."
  @spec reset(VisionCore.Config.t(), atom()) :: :ok | {:error, :not_found | String.t()}
  def reset(config, name) do
    with {:ok, settings} <- settings(config, name),
         :ok <- check_resettable(settings),
         :ok <- remove(settings.calibration_store_path) do
      changed(name)
    end
  end

  defp settings(config, name) do
    case Enum.find(Unit.settings(config), &(&1.name == name)) do
      nil -> {:error, :not_found}
      settings -> {:ok, settings}
    end
  end

  defp read(nil), do: {:ok, %{path: nil, calibration: nil, yaml: nil}}

  defp read(path) do
    case File.read(path) do
      {:ok, yaml} -> parse(path, yaml)
      {:error, :enoent} -> {:ok, %{path: path, calibration: nil, yaml: nil}}
      {:error, reason} -> {:error, "cannot read #{path}: #{file_error(reason)}"}
    end
  end

  defp parse(path, yaml) do
    {:ok, %{path: path, calibration: CameraCalibration.parse(yaml), yaml: yaml}}
  rescue
    exception -> {:error, "cannot parse #{path}: #{Exception.message(exception)}"}
  end

  defp source(%{calibration: nil}, _stored?), do: :none
  defp source(_camera, true), do: :stored
  defp source(_camera, false), do: :built_in

  defp stored?(%{calibration_store_path: nil}), do: false
  defp stored?(%{calibration_store_path: path}), do: File.exists?(path)

  defp built_in?(%{built_in_calibration_path: nil}), do: false
  defp built_in?(%{built_in_calibration_path: path}), do: File.exists?(path)

  defp written_at(path) do
    case File.stat(path, time: :posix) do
      {:ok, stat} -> DateTime.from_unix!(stat.mtime)
      {:error, _reason} -> nil
    end
  end

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

  defp write(path, yaml) do
    temporary = path <> ".tmp"

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(temporary, yaml),
         :ok <- File.rename(temporary, path) do
      Logger.info("#{__MODULE__} wrote #{byte_size(yaml)} B → #{path}")
    else
      {:error, reason} ->
        File.rm(temporary)
        {:error, "cannot write #{path}: #{file_error(reason)}"}
    end
  end

  defp remove(path) do
    case File.rm(path) do
      :ok -> Logger.info("#{__MODULE__} removed #{path}")
      {:error, reason} -> {:error, "cannot remove #{path}: #{file_error(reason)}"}
    end
  end

  defp changed(name), do: Outputs.publish(changed_key(name), {:camera_calibration_changed, name})

  defp file_error(reason), do: reason |> :file.format_error() |> List.to_string()
end
