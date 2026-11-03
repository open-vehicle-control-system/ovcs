defmodule VisionCore.Stereo.Stage.SharpnessTest do
  use ExUnit.Case, async: true

  alias VisionCore.Stereo.{NxSegment, Pair, Stage}

  defp measure(left, right) do
    {height, width} = Nx.shape(left)
    context = %{height: height, width: width}
    {:ok, state} = Stage.Sharpness.init([], context)
    member = %{module: Stage.Sharpness, name: :sharpness, state: state}
    {:ok, segment} = NxSegment.build([member], context, compiler: EXLA)

    {:ok, pair, _segment} =
      NxSegment.run(%Pair{left_frame: nil, right_frame: nil, left: left, right: right}, segment)

    pair.sharpness
  end

  defp texture do
    {texture, _key} = Nx.Random.randint(Nx.Random.key(3), 40, 216, shape: {64, 96}, type: :s32)
    Nx.as_type(texture, :f32)
  end

  # A 3x3 box blur, edges replicated.
  defp blur(image) do
    image
    |> Nx.reshape({1, 1, 64, 96})
    |> Nx.window_mean({1, 1, 3, 3}, padding: :same)
    |> Nx.reshape({64, 96})
  end

  defp u8(image), do: image |> Nx.round() |> Nx.clip(0, 255) |> Nx.as_type(:u8)

  test "reads the same sharpness for the same image" do
    image = u8(texture())
    %{left: left, right: right} = measure(image, image)
    assert left > 0
    assert_in_delta right / left, 1.0, 1.0e-4
  end

  test "reads a blurred image as less sharp" do
    %{left: left, right: right} = measure(u8(texture()), u8(blur(texture())))
    assert right / left < 0.5
  end

  test "is independent of brightness" do
    %{left: left, right: right} = measure(u8(texture()), u8(Nx.multiply(texture(), 0.5)))
    assert_in_delta right / left, 1.0, 0.05
  end

  test "leaves out each pair of neighbours a black pixel is in, as Rectification's borders" do
    # The texture has no black pixel of its own.
    image = u8(texture())
    black = &Nx.select(&1, Nx.u8(0), image)

    # Black rows, as right_row_offset leaves, and a black side, as a turned calibration does.
    for {blackened, rest} <- [
          {black.(Nx.less(Nx.iota({64, 96}, axis: 0), 6)), image[6..63]},
          {black.(Nx.less(Nx.iota({64, 96}, axis: 1), 10)), image[[.., 10..95]]}
        ] do
      %{left: measured} = measure(blackened, blackened)
      %{left: expected} = measure(rest, rest)
      assert_in_delta measured, expected, 1.0e-6 * expected
    end
  end

  test "reads 0 for an image where no two neighbours are both above black, as for a black one" do
    {rows, columns} = {Nx.iota({64, 96}, axis: 0), Nx.iota({64, 96}, axis: 1)}
    alternate = rows |> Nx.add(columns) |> Nx.remainder(2) |> Nx.equal(0)
    dotted = Nx.select(alternate, Nx.u8(120), Nx.u8(0))
    assert measure(dotted, Nx.broadcast(Nx.u8(0), {64, 96})) == %{left: 0.0, right: 0.0}
  end
end
