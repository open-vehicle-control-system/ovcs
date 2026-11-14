defmodule VisionCore.Calibration.SavedCamera do
  @moduledoc """
  One camera of a `VisionCore.Calibration.Saved`: its name in the target
  (`left`, `right`, or the camera's), the image size, the intrinsics
  `fx`, `fy`, `cx`, `cy`, the `plumb_bob` distortion `k1`, `k2`, `p1`,
  `p2`, `k3`, the rectification matrix `r00` to `r22` and the projection
  matrix `p00` to `p23`, each element a column, and the reprojection
  error of the solve that made it, when known.

  `attributes/2` and `to_calibration/1` convert from and to the
  `VisionCore.Ros2.CameraCalibration` the files hold. A calibration with
  another distortion model, another count of coefficients or a camera
  matrix with a skew has no columns to go to, and is refused.
  """
  use Ecto.Schema

  import Ecto.Changeset

  alias VisionCore.Calibration.Saved
  alias VisionCore.Ros2.CameraCalibration

  @distortion [:k1, :k2, :p1, :p2, :k3]
  @rectification for row <- 0..2, column <- 0..2, do: :"r#{row}#{column}"
  @projection for row <- 0..2, column <- 0..3, do: :"p#{row}#{column}"
  @distortion_model "plumb_bob"
  @required [:name, :image_width, :image_height, :fx, :fy, :cx, :cy] ++
              @distortion ++ @rectification ++ @projection

  @type t :: %__MODULE__{}

  schema "calibration_cameras" do
    belongs_to(:calibration, Saved)
    field(:name, :string)
    field(:image_width, :integer)
    field(:image_height, :integer)
    field(:fx, :float)
    field(:fy, :float)
    field(:cx, :float)
    field(:cy, :float)
    field(:rms_px, :float)

    for element <- @distortion ++ @rectification ++ @projection do
      field(element, :float)
    end
  end

  @doc "The changeset of `camera` with `attributes`; every column but `rms_px` is required."
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(%__MODULE__{} = camera, attributes) do
    camera
    |> cast(attributes, [:rms_px | @required])
    |> validate_required(@required)
  end

  @doc "The attributes of the camera `name` holding `calibration`, or why it has no columns to go to."
  @spec attributes(String.t(), CameraCalibration.t()) :: {:ok, map()} | {:error, String.t()}
  def attributes(name, %CameraCalibration{} = calibration) do
    with :ok <- check_model(calibration.distortion_model),
         {:ok, distortion} <-
           elements(calibration.distortion_coefficients, @distortion, "distortion coefficients"),
         {:ok, intrinsics} <- intrinsics(calibration.camera_matrix),
         {:ok, rectification} <-
           elements(calibration.rectification_matrix, @rectification, "rectification matrix"),
         {:ok, projection} <-
           elements(calibration.projection_matrix, @projection, "projection matrix") do
      fields =
        [name: name, image_width: calibration.width, image_height: calibration.height] ++
          intrinsics ++ distortion ++ rectification ++ projection

      {:ok, Map.new(fields)}
    end
  end

  @doc "The calibration `camera` holds, as the files carry it."
  @spec to_calibration(t()) :: CameraCalibration.t()
  def to_calibration(%__MODULE__{} = camera) do
    %CameraCalibration{
      width: camera.image_width,
      height: camera.image_height,
      distortion_model: @distortion_model,
      distortion_coefficients: Enum.map(@distortion, &Map.fetch!(camera, &1)),
      camera_matrix: [camera.fx, 0.0, camera.cx, 0.0, camera.fy, camera.cy, 0.0, 0.0, 1.0],
      rectification_matrix: Enum.map(@rectification, &Map.fetch!(camera, &1)),
      projection_matrix: Enum.map(@projection, &Map.fetch!(camera, &1))
    }
  end

  @doc "Whether `camera` holds `calibration`, element for element."
  @spec holds?(t(), CameraCalibration.t()) :: boolean()
  def holds?(%__MODULE__{} = camera, %CameraCalibration{} = calibration) do
    case attributes(camera.name, calibration) do
      {:ok, other} -> Enum.all?(compared(), &same?(Map.fetch!(camera, &1), Map.fetch!(other, &1)))
      {:error, _reason} -> false
    end
  end

  defp compared,
    do:
      [:image_width, :image_height, :fx, :fy, :cx, :cy] ++
        @distortion ++ @rectification ++ @projection

  # A value read back from its file differs from the column by the text's rounding at most.
  defp same?(left, right), do: abs(left - right) <= 1.0e-9 * max(1.0, abs(left))

  defp check_model(@distortion_model), do: :ok

  defp check_model(model),
    do: {:error, "the distortion model #{inspect(model)} is not #{@distortion_model}"}

  defp elements(values, names, _what) when is_list(values) and length(values) == length(names),
    do: {:ok, Enum.zip(names, Enum.map(values, &(&1 * 1.0)))}

  defp elements(_values, names, what), do: {:error, "the #{what} do not count #{length(names)}"}

  defp intrinsics([fx, skew, cx, zero_a, fy, cy, zero_b, zero_c, one])
       when skew == 0 and zero_a == 0 and zero_b == 0 and zero_c == 0 and one == 1,
       do: {:ok, [fx: fx * 1.0, fy: fy * 1.0, cx: cx * 1.0, cy: cy * 1.0]}

  defp intrinsics(_matrix), do: {:error, "the camera matrix is not fx, fy, cx and cy alone"}
end
