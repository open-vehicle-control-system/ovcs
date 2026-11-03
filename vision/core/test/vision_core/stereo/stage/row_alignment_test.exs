defmodule VisionCore.Stereo.Stage.RowAlignmentTest do
  use ExUnit.Case, async: true

  alias VisionCore.Stereo.{NxSegment, Pair, Stage}

  @height 64
  @width 128
  @disparity 8

  # Options: `:matched` (every pixel), `:unmatched_disparity` (-1.0), `:uniform_columns` (0).
  defp measure(row_offset, opts \\ []) do
    {texture, _key} =
      Nx.Random.randint(Nx.Random.key(7), 0, 256,
        shape: {@height + 8, @width + @disparity},
        type: :s32
      )

    uniform = Nx.less(Nx.iota(Nx.shape(texture), axis: 1), Keyword.get(opts, :uniform_columns, 0))
    first_row = Nx.broadcast(texture[0], Nx.shape(texture))
    texture = uniform |> Nx.select(first_row, texture) |> Nx.as_type(:u8)
    # A left pixel (y, x) matches the right pixel (y + row_offset, x - @disparity).
    left = Nx.slice(texture, [4, 0], [@height, @width])
    right = Nx.slice(texture, [4 - row_offset, @disparity], [@height, @width])
    matched = Keyword.get_lazy(opts, :matched, fn -> columns_from(0) end)
    unmatched_disparity = Keyword.get(opts, :unmatched_disparity, -1.0)
    disparity = Nx.select(matched, Nx.f32(@disparity), Nx.f32(unmatched_disparity))

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

  defp columns_from(first), do: Nx.greater_equal(Nx.iota({@height, @width}, axis: 1), first)

  # One pixel on each sampled row of the first band.
  defp one_column, do: Nx.equal(Nx.iota({@height, @width}, axis: 1), 16)

  test "reads no offset on an aligned pair" do
    pair = measure(0)
    assert_in_delta pair.alignment.offset_rows, 0.0, 0.1
    assert length(pair.alignment.band_offset_rows) == 4
  end

  test "reads the rows the right image is offset by" do
    assert_in_delta measure(1).alignment.offset_rows, 1.0, 0.1
    assert_in_delta measure(-2).alignment.offset_rows, -2.0, 0.15
  end

  test "reads no offset in a band without a matched pixel" do
    pair = measure(1, matched: columns_from(div(@width, 4)))
    assert [nil | rest] = pair.alignment.band_offset_rows
    for band <- rest, do: assert_in_delta(band, 1.0, 0.1)
  end

  test "reads a disparity of 0 as unmatched" do
    pair = measure(1, matched: columns_from(div(@width, 4)), unmatched_disparity: 0.0)
    assert [nil | rest] = pair.alignment.band_offset_rows
    for band <- rest, do: assert_in_delta(band, 1.0, 0.1)
  end

  test "reads no offset in a band with too few matched pixels" do
    pair = measure(1, matched: Nx.logical_or(columns_from(div(@width, 4)), one_column()))
    assert [nil | rest] = pair.alignment.band_offset_rows
    for band <- rest, do: assert_in_delta(band, 1.0, 0.1)
  end

  test "reads no offset in a band whose lowest difference is not unique" do
    # The first band the same on every row in both images: every row offset compares alike.
    pair = measure(1, uniform_columns: div(@width, 4) + @disparity)
    assert [nil | rest] = pair.alignment.band_offset_rows
    for band <- rest, do: assert_in_delta(band, 1.0, 0.1)
    assert_in_delta pair.alignment.offset_rows, 1.0, 0.1
  end

  test "reads and reports no offset when too few pixels matched in the whole image" do
    pair = measure(1, matched: one_column())
    assert pair.alignment == nil
    assert pair.metrics == []
  end

  test "reads and reports no offset when the whole image's lowest difference is not unique" do
    pair = measure(1, uniform_columns: @width + @disparity)
    assert pair.alignment == nil
    assert pair.metrics == []
  end

  test "reports the offset as a metric for the pipeline's log line" do
    assert [{:align_rows, value, "rows"}] = measure(1).metrics
    assert_in_delta value, 1.0, 0.1
  end
end
