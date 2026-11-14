defmodule VisionCore.Models.KeptCalibrationId do
  @moduledoc """
  The id of a calibration kept: its kind, then its row's id, as
  `stereo-12`, `camera-5` or `pose-3`. The three kinds are kept in three
  tables whose row ids overlap; the kind makes the id name one
  calibration. The primary key of `VisionCore.Models.StereoCameraCalibration`,
  `VisionCore.Models.CameraCalibration` and `VisionCore.Models.CameraPose`,
  each with its `:kind`.
  """
  use Ecto.ParameterizedType

  @kinds ["stereo", "camera", "pose"]
  @pattern ~r/\A(stereo|camera|pose)-([1-9][0-9]{0,17})\z/

  @type t :: String.t()

  @doc "The kind and the row's id `id` names, or `:error` for text that names no calibration kept."
  @spec parse(term()) :: {:ok, String.t(), pos_integer()} | :error
  def parse(id) when is_binary(id) do
    case Regex.run(@pattern, id, capture: :all_but_first) do
      [kind, row_id] -> {:ok, kind, String.to_integer(row_id)}
      nil -> :error
    end
  end

  def parse(_id), do: :error

  @impl Ecto.ParameterizedType
  def type(_kind), do: :id

  @impl Ecto.ParameterizedType
  def init(opts) do
    kind = Keyword.fetch!(opts, :kind)
    if kind in @kinds, do: kind, else: raise(ArgumentError, "no kind #{inspect(kind)}")
  end

  @impl Ecto.ParameterizedType
  def cast(nil, _kind), do: {:ok, nil}

  def cast(id, kind) do
    case parse(id) do
      {:ok, ^kind, _row_id} -> {:ok, id}
      _other -> :error
    end
  end

  @impl Ecto.ParameterizedType
  def load(nil, _loader, _kind), do: {:ok, nil}
  def load(row_id, _loader, kind) when is_integer(row_id), do: {:ok, "#{kind}-#{row_id}"}
  def load(_row_id, _loader, _kind), do: :error

  @impl Ecto.ParameterizedType
  def dump(nil, _dumper, _kind), do: {:ok, nil}

  def dump(id, _dumper, kind) do
    case parse(id) do
      {:ok, ^kind, row_id} -> {:ok, row_id}
      _other -> :error
    end
  end
end
