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
end
