defmodule VisionCore.Stereo.Stage.Sharpness do
  @moduledoc """
  Measures how sharp each rectified image is, to compare the cameras'
  focus: the mean squared difference between horizontally neighbouring
  pixels over the square of the mean grey, summed on the device.
  Dividing by the brightness keeps an exposure difference between the
  cameras out of it; the absolute value depends on the scene, so it is
  the ratio of the two that tells their focus apart.

  A pair of neighbours counts only where neither pixel is black, 0:
  `VisionCore.Stereo.Stage.Rectification` writes 0 wherever it samples
  outside the camera frame, such as the rows `:right_row_offset` moves
  out of it and the wedges a turned calibration leaves at the image's
  edges. Pixels the camera itself saw as black are left out with them.
  Both means are over the pairs an image counts, and an image without
  any reads 0. The pair's `:sharpness` is `%{left: float, right: float}`.
  """
  @behaviour VisionCore.Stereo.NxStage

  alias VisionCore.Parameters.Check
  alias VisionCore.Stereo.{NxStage, Pair}

  @impl VisionCore.Stereo.NxStage
  def summary, do: "Measures each rectified image's sharpness, to compare the cameras' focus."

  @impl VisionCore.Stereo.NxStage
  def explanation,
    do:
      "Measures how sharp each rectified image is. The value itself depends on the scene; " <>
        "what matters is how the two cameras compare, shown as Sharpness, right / left " <>
        "between the videos. Near 1, both cameras are focused alike. Far from 1, one of them " <>
        "is out of focus compared with the other, and matching loses detail: refocus that " <>
        "camera. Black pixels are left out, among them the borders rectification leaves " <>
        "where it reaches past a camera's frame. It has no settings."

  @impl VisionCore.Stereo.NxStage
  def init(opts, _context) do
    with {:ok, _no_settings} <- Check.init_settings([], %{}, opts), do: {:ok, nil}
  end

  @impl VisionCore.Stereo.NxStage
  def requires, do: [:left, :right]

  @impl VisionCore.Stereo.NxStage
  def provides, do: [:sharpness]

  @impl VisionCore.Stereo.NxStage
  def step(tensors, _params, _state),
    do: Map.put(tensors, :sharpness_sums, sums(tensors.left, tensors.right))

  @impl VisionCore.Stereo.NxStage
  def finish(%Pair{} = pair, outputs, _state) do
    [left_energy, right_energy, left_grey, right_grey, left_pairs, right_pairs] =
      Nx.to_flat_list(outputs.sharpness_sums)

    sharpness = fn energy, grey, pairs ->
      if grey > 0, do: energy * pairs / (grey * grey), else: 0.0
    end

    %{
      pair
      | sharpness: %{
          left: sharpness.(left_energy, left_grey, left_pairs),
          right: sharpness.(right_energy, right_grey, right_pairs)
        }
    }
  end

  defp sums(left, right) do
    {left_energy, left_grey, left_pairs} = planes(left)
    {right_energy, right_grey, right_pairs} = planes(right)

    [left_energy, right_energy, left_grey, right_grey, left_pairs, right_pairs]
    |> Nx.stack()
    |> NxStage.image_sums()
  end

  # Per pair of horizontal neighbours both above black: their squared difference, the left one's grey, 1.
  defp planes(image) do
    {_height, width} = Nx.shape(image)
    image = Nx.as_type(image, :f32)
    pixels = Nx.slice_along_axis(image, 0, width - 1, axis: 1)
    neighbours = Nx.slice_along_axis(image, 1, width - 1, axis: 1)

    counted =
      pixels |> Nx.greater(0) |> Nx.logical_and(Nx.greater(neighbours, 0)) |> Nx.as_type(:f32)

    difference = Nx.subtract(neighbours, pixels)
    energy = difference |> Nx.multiply(difference) |> Nx.multiply(counted)
    {energy, Nx.multiply(pixels, counted), counted}
  end
end
