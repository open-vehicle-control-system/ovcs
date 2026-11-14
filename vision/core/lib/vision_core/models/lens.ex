defmodule VisionCore.Models.Lens do
  @moduledoc """
  A camera's lens as a calibration kept holds it, embedded in its
  `VisionCore.Models.StereoCameraCalibration` or
  `VisionCore.Models.CameraCalibration` and stored as JSON there: the
  image size, the intrinsics `fx`, `fy`, `cx`, `cy`, the `plumb_bob`
  distortion `k1`, `k2`, `p1`, `p2`, `k3`, the `rectification` matrix (3×3)
  and the `projection` matrix (3×4), row by row, and the reprojection
  error of the solve that made it, when known.

  `attributes/1` and `to_calibration/1` convert from and to the
  `VisionCore.Ros2.CameraCalibration` the files hold. A calibration with
  another distortion model, another count of coefficients or a camera
  matrix with a skew has no fields to go to, and is refused.
  """
  use Ecto.Schema

  import Ecto.Changeset

  alias VisionCore.Ros2.CameraCalibration

  @distortion [:k1, :k2, :p1, :p2, :k3]
  @rectification_size 9
  @projection_size 12
  @distortion_model "plumb_bob"
  @required [:image_width, :image_height, :fx, :fy, :cx, :cy, :rectification, :projection] ++
              @distortion

  @type t :: %__MODULE__{}

  @primary_key false
  embedded_schema do
    field(:image_width, :integer)
    field(:image_height, :integer)
    field(:fx, :float)
    field(:fy, :float)
    field(:cx, :float)
    field(:cy, :float)

    for coefficient <- @distortion do
      field(coefficient, :float)
    end

    field(:rectification, {:array, :float})
    field(:projection, {:array, :float})
    field(:rms_px, :float)
  end

  @doc "The changeset of `lens` with `attributes`; every field but `rms_px` is required."
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(%__MODULE__{} = lens, attributes) do
    lens
    |> cast(attributes, [:rms_px | @required])
    |> validate_required(@required)
    |> validate_length(:rectification, is: @rectification_size)
    |> validate_length(:projection, is: @projection_size)
  end

  @doc "The attributes of the lens holding `calibration`, or why it has no fields to go to."
  @spec attributes(CameraCalibration.t()) :: {:ok, map()} | {:error, String.t()}
  def attributes(%CameraCalibration{} = calibration) do
    with :ok <- check_model(calibration.distortion_model),
         {:ok, distortion} <-
           elements(calibration.distortion_coefficients, @distortion, "distortion coefficients"),
         {:ok, intrinsics} <- intrinsics(calibration.camera_matrix),
         {:ok, rectification} <-
           matrix(calibration.rectification_matrix, @rectification_size, "rectification matrix"),
         {:ok, projection} <-
           matrix(calibration.projection_matrix, @projection_size, "projection matrix") do
      fields =
        [
          image_width: calibration.width,
          image_height: calibration.height,
          rectification: rectification,
          projection: projection
        ] ++ intrinsics ++ distortion

      {:ok, Map.new(fields)}
    end
  end

  @doc "The calibration `lens` holds, as the files carry it."
  @spec to_calibration(t()) :: CameraCalibration.t()
  def to_calibration(%__MODULE__{} = lens) do
    %CameraCalibration{
      width: lens.image_width,
      height: lens.image_height,
      distortion_model: @distortion_model,
      distortion_coefficients: Enum.map(@distortion, &Map.fetch!(lens, &1)),
      camera_matrix: [lens.fx, 0.0, lens.cx, 0.0, lens.fy, lens.cy, 0.0, 0.0, 1.0],
      rectification_matrix: lens.rectification,
      projection_matrix: lens.projection
    }
  end

  @doc "Whether `lens` holds `calibration`, element for element."
  @spec holds?(t(), CameraCalibration.t()) :: boolean()
  def holds?(%__MODULE__{} = lens, %CameraCalibration{} = calibration) do
    case attributes(calibration) do
      {:ok, other} -> same?(figures(lens), figures(other))
      {:error, _reason} -> false
    end
  end

  defp figures(lens) do
    [lens.image_width, lens.image_height, lens.fx, lens.fy, lens.cx, lens.cy] ++
      Enum.map(@distortion, &Map.fetch!(lens, &1)) ++ lens.rectification ++ lens.projection
  end

  defp same?(held, given), do: Enum.all?(Enum.zip_with(held, given, &close?/2))

  # A value read back from its file differs from the one kept by the text's rounding at most.
  defp close?(left, right), do: abs(left - right) <= 1.0e-9 * max(1.0, abs(left))

  defp check_model(@distortion_model), do: :ok

  defp check_model(model),
    do: {:error, "the distortion model #{inspect(model)} is not #{@distortion_model}"}

  defp elements(values, names, what) do
    with {:ok, floats} <- matrix(values, length(names), what), do: {:ok, Enum.zip(names, floats)}
  end

  defp matrix(values, size, _what) when is_list(values) and length(values) == size,
    do: {:ok, Enum.map(values, &(&1 * 1.0))}

  defp matrix(_values, size, what), do: {:error, "the #{what} do not count #{size}"}

  defp intrinsics([fx, skew, cx, zero_a, fy, cy, zero_b, zero_c, one])
       when skew == 0 and zero_a == 0 and zero_b == 0 and zero_c == 0 and one == 1,
       do: {:ok, [fx: fx * 1.0, fy: fy * 1.0, cx: cx * 1.0, cy: cy * 1.0]}

  defp intrinsics(_matrix), do: {:error, "the camera matrix is not fx, fy, cx and cy alone"}
end
