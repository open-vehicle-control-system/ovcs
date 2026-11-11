defmodule VisionCore.Camera.Pose do
  @moduledoc """
  The pose of a camera of its own (`VisionCore.Camera.Unit`) relative to
  the stereo pair: the transform from the rectified left optical frame,
  the frame of the stereo depth, to the camera's optical frame,

      p_camera = rotation * p_left + translation

  `rotation` a 3x3 matrix, row-major, and `translation` in metres. The
  `:camera` component's `:pose` names its YAML, which
  `scripts/camera_pose.py` writes:

      rotation: [r00, r01, r02, r10, r11, r12, r20, r21, r22]
      translation: [tx, ty, tz]

  Other keys, such as the script's `rms_px`, are ignored.
  """

  defstruct [:rotation, :translation]

  @type t :: %__MODULE__{rotation: [float()], translation: [float()]}

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

  defp parse(yaml) do
    with {:ok, %{} = document} <- read_yaml(yaml),
         {:ok, rotation} <- numbers(document, "rotation", 9),
         {:ok, translation} <- numbers(document, "translation", 3) do
      {:ok, %__MODULE__{rotation: rotation, translation: translation}}
    else
      {:ok, _not_a_map} -> {:error, {:malformed, "not a map of rotation and translation"}}
      {:error, message} -> {:error, {:malformed, message}}
    end
  end

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
