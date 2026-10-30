defmodule VisionCore.Stereo.Stage.RowAlignmentTest do
  use ExUnit.Case, async: true

  alias VisionCore.Stereo.{NxSegment, Pair, Stage}

  @height 64
  @width 128
  @disparity 8

  defp measure(row_offset) do
    {texture, _key} =
      Nx.Random.randint(Nx.Random.key(7), 0, 256,
        shape: {@height + 8, @width + @disparity},
        type: :s32
      )

    texture = Nx.as_type(texture, :u8)
    # A left pixel (y, x) matches the right pixel (y + row_offset, x - @disparity).
    left = Nx.slice(texture, [4, 0], [@height, @width])
    right = Nx.slice(texture, [4 - row_offset, @disparity], [@height, @width])
    disparity = Nx.broadcast(Nx.f32(@disparity), {@height, @width})

    context = %{height: @height, width: @width}
    {:ok, state} = Stage.RowAlignment.init([], context)
    member = %{module: Stage.RowAlignment, name: :row_alignment, state: state}
    {:ok, segment} = NxSegment.build([member], context, compiler: EXLA)

    pair = %Pair{
      left_frame: nil,
      right_frame: nil,
      left: left,
      right: right,
      disparity: disparity
    }

    {:ok, pair, _segment} = NxSegment.run(pair, segment)
    pair
  end

  test "reads no offset on an aligned pair" do
    pair = measure(0)
    assert_in_delta pair.alignment.offset_rows, 0.0, 0.1
    assert length(pair.alignment.band_offset_rows) == 4
  end

  test "reads the rows the right image is offset by" do
    assert_in_delta measure(1).alignment.offset_rows, 1.0, 0.1
    assert_in_delta measure(-2).alignment.offset_rows, -2.0, 0.15
  end

  test "reports the offset as a metric for the pipeline's log line" do
    assert [{:align_rows, value, "rows"}] = measure(1).metrics
    assert_in_delta value, 1.0, 0.1
  end
end
