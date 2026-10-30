defmodule VisionCore.Stereo.Stage.Sharpness do
  @moduledoc """
  Measures how sharp each rectified image is, to compare the cameras'
  focus: the mean squared difference between horizontally neighbouring
  pixels over the square of the mean grey, summed on the device. Dividing by the brightness keeps an exposure difference
  between the cameras out of it; the absolute value depends on the
  scene, so it is the ratio of the two that tells their focus apart. The
  pair's `:sharpness` is `%{left: float, right: float}`.
  """
  @behaviour VisionCore.Stereo.NxStage

  alias VisionCore.Stereo.Pair

  @impl VisionCore.Stereo.NxStage
  def init(_opts, context), do: {:ok, %{size: {context.height, context.width}}}

  @impl VisionCore.Stereo.NxStage
  def requires, do: [:left, :right]

  @impl VisionCore.Stereo.NxStage
  def provides, do: [:sharpness]

  @impl VisionCore.Stereo.NxStage
  def params(_state, _context), do: %{}

  @impl VisionCore.Stereo.NxStage
  def step(tensors, _params, _state),
    do: Map.put(tensors, :sharpness_sums, sums(tensors.left, tensors.right))

  @impl VisionCore.Stereo.NxStage
  def finish(%Pair{} = pair, outputs, _state) do
    [left_energy, right_energy, left_grey, right_grey, samples] =
      Nx.to_flat_list(outputs.sharpness_sums)

    sharpness = fn energy, grey ->
      if grey > 0, do: energy * samples / (grey * grey), else: 0.0
    end

    %{
      pair
      | sharpness: %{
          left: sharpness.(left_energy, left_grey),
          right: sharpness.(right_energy, right_grey)
        }
    }
  end

  # Image planes summed by rows first: other layouts compile to slow GPU reductions.
  defp sums(left, right) do
    {left_energy, left_grey} = planes(left)
    {right_energy, right_grey} = planes(right)
    count = Nx.broadcast(Nx.f32(1), Nx.shape(left_grey))

    [left_energy, right_energy, left_grey, right_grey, count]
    |> Nx.stack()
    |> Nx.sum(axes: [1])
    |> Nx.sum(axes: [1])
  end

  defp planes(image) do
    {_height, width} = Nx.shape(image)

    rows = Nx.as_type(image, :f32)

    {grey, next} =
      {Nx.slice_along_axis(rows, 0, width - 1, axis: 1),
       Nx.slice_along_axis(rows, 1, width - 1, axis: 1)}

    difference = Nx.subtract(next, grey)
    {Nx.multiply(difference, difference), grey}
  end
end
