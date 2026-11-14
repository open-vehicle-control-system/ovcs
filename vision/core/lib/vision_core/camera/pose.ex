defmodule VisionCore.Camera.Pose do
  @moduledoc """
  The pose of a camera of its own (`VisionCore.Camera.Unit`) relative to
  the stereo pair: the transform from the rectified left optical frame,
  the frame of the stereo depth, to the camera's optical frame,

      p_camera = rotation * p_left + translation

  `rotation` a 3x3 matrix, row-major, and `translation` in metres, in a
  YAML of its own:

      rotation: [r00, r01, r02, r10, r11, r12, r20, r21, r22]
      translation: [tx, ty, tz]

  Other keys are ignored.

  The dashboard solves it (`VisionCore.Calibration.Session`) and stores it
  as a camera's calibration is stored: with a `:calibration_store_dir`, a
  pose committed goes to `camera_<name>_pose.yaml` there and is the one in
  force; the camera's `:pose` holds the built-in one, which `reset/2`
  goes back to. Without a store, a commit writes the `:pose` path itself.
  The file is written whole or not at all (`VisionCore.Camera.StoredFile`),
  and the commits and resets of one camera's pose run one at a time.

  Each commit or reset is published as `{:camera_pose_changed, name}`
  under `changed_key/1`: the pipelines on the camera and the ROS 2
  exporter read the pose again.
  """
  require Logger

  alias VisionCore.Camera.{StoredFile, Unit}
  alias VisionCore.Outputs

  defstruct [:rotation, :translation]

  @type t :: %__MODULE__{rotation: [float()], translation: [float()]}

  @typedoc """
  The pose in force of a camera: where it comes from, when a stored one
  was written, whether it can go back to a built-in one, its path, the
  pose and its YAML, `nil` without a file, and why a file gives no pose.
  """
  @type in_use :: %{
          source: :stored | :built_in | :none,
          stored_at: DateTime.t() | nil,
          can_reset: boolean(),
          path: Path.t() | nil,
          pose: t() | nil,
          yaml: String.t() | nil,
          error: String.t() | nil
        }

  @doc "The `VisionCore.Outputs` key a change of the pose of the camera `name` is published under."
  @spec changed_key(atom()) :: {:camera_pose, atom()}
  def changed_key(name), do: {:camera_pose, name}

  @doc """
  Reads the pose YAML at `path`. `{:error, reason}` with `File`'s
  reason when it cannot be read, `{:error, {:malformed, message}}` when
  it is not a map of a 9-number `rotation` and a 3-number `translation`.
  """
  @spec load(Path.t()) :: {:ok, t()} | {:error, term()}
  def load(path) do
    with {:ok, yaml} <- File.read(path) do
      parse(yaml)
    end
  end

  @doc "Reads a pose YAML text, as `load/1` reads its file."
  @spec parse(String.t()) :: {:ok, t()} | {:error, {:malformed, String.t()}}
  def parse(yaml) do
    with {:ok, %{} = document} <- read_yaml(yaml),
         {:ok, rotation} <- numbers(document, "rotation", 9),
         {:ok, translation} <- numbers(document, "translation", 3) do
      {:ok, %__MODULE__{rotation: rotation, translation: translation}}
    else
      {:ok, _not_a_map} -> {:error, {:malformed, "not a map of rotation and translation"}}
      {:error, message} -> {:error, {:malformed, message}}
    end
  end

  @doc "The pose YAML of `pose`, each number written so that it reads back the same."
  @spec to_yaml(t()) :: String.t()
  def to_yaml(%__MODULE__{rotation: rotation, translation: translation}) do
    """
    # From the rectified left optical frame to the camera's optical frame:
    # p_camera = rotation * p_left + translation, in metres.
    rotation: [#{numbers_text(rotation)}]
    translation: [#{numbers_text(translation)}]
    """
  end

  defp numbers_text(numbers), do: Enum.map_join(numbers, ", ", &Float.to_string(&1 * 1.0))

  @doc "The distance between the two cameras' optical centres, in metres."
  @spec distance_m(t()) :: float()
  def distance_m(%__MODULE__{translation: translation}),
    do: :math.sqrt(Enum.sum(Enum.map(translation, &(&1 * &1))))

  @doc """
  The pose in force for the camera `name` of `config`, the active
  `VisionCore.Config`. `stored_at` is the time the stored file was
  written, and `can_reset` whether one is stored with a built-in pose to
  go back to. A file that cannot be read or parsed gives no pose, and
  `error` says why, which is logged. `{:error, :not_found}` for a camera
  `config` has not.
  """
  @spec in_use(VisionCore.Config.t(), atom()) :: {:ok, in_use()} | {:error, :not_found}
  def in_use(config, name) do
    with {:ok, settings} <- settings(config, name) do
      {read, error} = read(settings.pose_path)
      if error, do: Logger.warning("#{__MODULE__}[#{name}] #{error}")
      stored? = stored?(settings)

      {:ok,
       Map.merge(read, %{
         source: source(read.pose, stored?),
         stored_at: if(stored?, do: StoredFile.written_at(settings.pose_store_path)),
         can_reset: stored? and built_in?(settings),
         path: settings.pose_path,
         error: error
       })}
    end
  end

  @doc "Writes `pose` as the camera `name`'s, to its store when it has one, else to its `:pose` path."
  @spec commit(VisionCore.Config.t(), atom(), t()) :: :ok | {:error, :not_found | String.t()}
  def commit(config, name, %__MODULE__{} = pose) do
    with {:ok, settings} <- settings(config, name),
         {:ok, path} <- writable_path(settings) do
      locked(name, fn ->
        with :ok <- StoredFile.write(path, to_yaml(pose), __MODULE__), do: changed(name)
      end)
    end
  end

  @doc "Removes the camera `name`'s stored pose, so that its built-in one is in force again."
  @spec reset(VisionCore.Config.t(), atom()) :: :ok | {:error, :not_found | String.t()}
  def reset(config, name) do
    with {:ok, settings} <- settings(config, name) do
      locked(name, fn ->
        with :ok <- check_resettable(settings),
             :ok <- StoredFile.remove(settings.pose_store_path, __MODULE__),
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

  # The pose and its YAML, and why the file gives no pose, `nil` when it does or there is no file.
  defp read(nil), do: {%{pose: nil, yaml: nil}, nil}

  defp read(path) do
    with {:ok, yaml} <- File.read(path),
         {:ok, pose} <- parse(yaml) do
      {%{pose: pose, yaml: yaml}, nil}
    else
      {:error, :enoent} ->
        {%{pose: nil, yaml: nil}, nil}

      {:error, {:malformed, message}} ->
        {%{pose: nil, yaml: nil}, "#{path}: #{message}"}

      {:error, reason} ->
        {%{pose: nil, yaml: nil}, "cannot read #{path}: #{StoredFile.file_error(reason)}"}
    end
  end

  defp source(nil, _stored?), do: :none
  defp source(_pose, true), do: :stored
  defp source(_pose, false), do: :built_in

  defp stored?(%{pose_store_path: nil}), do: false
  defp stored?(%{pose_store_path: path}), do: File.exists?(path)

  defp built_in?(%{built_in_pose_path: nil}), do: false
  defp built_in?(%{built_in_pose_path: path}), do: File.exists?(path)

  defp writable_path(settings) do
    case settings.pose_store_path || settings.built_in_pose_path do
      nil -> {:error, "the camera has no pose path to write"}
      path -> {:ok, path}
    end
  end

  defp check_resettable(%{pose_store_path: nil}),
    do: {:error, "the camera has no calibration store"}

  defp check_resettable(settings) do
    cond do
      not stored?(settings) -> {:error, "nothing is stored"}
      not built_in?(settings) -> {:error, "there is no built-in pose to return to"}
      true -> :ok
    end
  end

  defp changed(name), do: Outputs.publish(changed_key(name), {:camera_pose_changed, name})

  defp read_yaml(yaml) do
    case YamlElixir.read_from_string(yaml) do
      {:ok, document} -> {:ok, document}
      {:error, error} -> {:error, "not YAML: #{Exception.message(error)}"}
    end
  end

  defp numbers(document, key, count) do
    case Map.get(document, key) do
      list when is_list(list) and length(list) == count ->
        if Enum.all?(list, &is_number/1),
          do: {:ok, Enum.map(list, &(&1 / 1))},
          else: {:error, "#{key} is not #{count} numbers"}

      _missing_or_wrong ->
        {:error, "#{key} is not #{count} numbers"}
    end
  end
end
