defmodule VisionCore.Stereo.SegmentTest do
  use ExUnit.Case, async: true

  alias VisionCore.Camera.Frame
  alias VisionCore.Stereo.{Pair, Segment}

  defmodule Rectifies do
    def requires, do: [:left_frame, :right_frame]
    def provides, do: [:left, :right]
  end

  defmodule Filters do
    def requires, do: [:left, :disparity]
    def provides, do: [:disparity]
  end

  defmodule ReadsDepth do
    def requires, do: [:depth]
    def provides, do: []
  end

  @context %{width: 4, height: 2, frame_width: 6, frame_height: 3}

  defp members(modules), do: for(module <- modules, do: %{module: module, name: module})

  defp frame(width, height),
    do: %Frame{
      label: "left",
      grey: :binary.copy(<<7>>, width * height),
      width: width,
      height: height,
      capture_ns: 0
    }

  test "takes the frames and images at the frame and working sizes, as u8, and the disparity as f32" do
    assert Segment.entry_specs(members([Rectifies]), @context) ==
             {:ok, [left_frame: {{3, 6}, {:u, 8}}, right_frame: {{3, 6}, {:u, 8}}]}

    assert Segment.entry_specs(members([Filters]), @context) ==
             {:ok, [left: {{2, 4}, {:u, 8}}, disparity: {{2, 4}, {:f, 32}}]}

    assert Segment.entry_specs(members([Rectifies, Filters]), @context) ==
             {:ok,
              [
                left_frame: {{3, 6}, {:u, 8}},
                right_frame: {{3, 6}, {:u, 8}},
                disparity: {{2, 4}, {:f, 32}}
              ]}
  end

  test "cannot take a field only a CPU stage fills" do
    assert Segment.entry_specs(members([ReadsDepth]), @context) ==
             {:error, "a segment cannot read :depth from a CPU stage"}
  end

  test "takes a pair's entry fields as tensors of their spec, or says why it cannot" do
    {:ok, specs} = Segment.entry_specs(members([Rectifies, Filters]), @context)
    disparity = Nx.broadcast(Nx.f64(1.5), {2, 4})
    pair = %Pair{left_frame: frame(6, 3), right_frame: frame(6, 3), disparity: disparity}

    assert {:ok, [left_frame: left, right_frame: _right, disparity: converted]} =
             Segment.entry_tensors(pair, specs)

    assert {Nx.shape(left), Nx.type(left)} == {{3, 6}, {:u, 8}}
    assert Nx.type(converted) == {:f, 32}

    assert Segment.entry_tensors(%{pair | right_frame: frame(4, 2)}, specs) ==
             {:error, {:frame_size, :right_frame, {2, 4}, {3, 6}}}

    assert Segment.entry_tensors(%{pair | disparity: nil}, specs) ==
             {:error, {:not_a_tensor, :disparity, nil}}

    short = %{frame(6, 3) | grey: :binary.copy(<<7>>, 10)}

    assert Segment.entry_tensors(%{pair | left_frame: short}, specs) ==
             {:error, {:frame_bytes, :left_frame, 10, 18}}
  end
end
