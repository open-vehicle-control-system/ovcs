defmodule VisionCore.Stereo.TestHelpersTest do
  use ExUnit.Case, async: true

  import VisionCore.Stereo.TestHelpers

  alias VisionCore.Camera.Frame
  alias VisionCore.Stereo.{Matcher, NxSegment, Pair, Stage}

  @context %{height: 12, width: 16}

  # A 20x30 surface at disparity 10 with a 3x3 blob at 30 in it, centred on row 9, column 13.
  defp blob_disparity do
    Nx.broadcast(Nx.f32(10.0), {20, 30})
    |> Nx.put_slice([8, 12], Nx.broadcast(Nx.f32(30.0), {3, 3}))
  end

  test "calibration_path/2 names the files of a calibration's two sides" do
    for side <- [:left, :right], calibration <- [:stereo, :identity, :distorted] do
      assert File.exists?(calibration_path(calibration, side))
    end
  end

  test "context/4 is the stages' context at the working size, with the size the frames come in" do
    assert %{width: 64, height: 48, frame_width: 96, frame_height: 72} =
             context(:distorted, 64, 48, {96, 72})

    assert %{width: 40, height: 30, frame_width: 40, frame_height: 30, focal_length_px: focal} =
             context(:stereo, 40, 30)

    assert focal > 0
  end

  test "texture/3 is the same u8 image for the same seed, and another for another" do
    image = texture(6, 8, 1)

    assert {Nx.shape(image), Nx.type(image)} == {{6, 8}, {:u, 8}}
    assert Nx.to_binary(image) == Nx.to_binary(texture(6, 8, 1))
    refute Nx.to_binary(image) == Nx.to_binary(texture(6, 8, 2))
  end

  test "frame/1 and frames_pair/2 wrap grey images as camera frames" do
    image = texture(6, 8, 1)

    assert %Frame{width: 8, height: 6, grey: grey, jpeg: nil} = frame(image)
    assert grey == Nx.to_binary(image)

    assert %Pair{left_frame: %Frame{grey: left}, right_frame: %Frame{grey: right}} =
             frames_pair(image, Nx.reverse(image))

    assert {left, right} == {Nx.to_binary(image), Nx.to_binary(Nx.reverse(image))}
  end

  test "pair/1 is a pair without frames, with the fields it is given" do
    disparity = blob_disparity()

    assert %Pair{left_frame: nil, right_frame: nil, disparity: ^disparity, left: nil} =
             pair(disparity: disparity)

    assert pair(%{disparity: disparity}) == pair(disparity: disparity)
  end

  test "members/2 initialises stages given as modules, or as modules with options" do
    stages = [Stage.Quality, {Stage.SpeckleFilter, [min_support: 7]}]

    assert [
             %{module: Stage.Quality, name: Stage.Quality, state: _quality},
             %{module: Stage.SpeckleFilter, name: Stage.SpeckleFilter, state: speckle}
           ] = members(stages, @context)

    assert Stage.SpeckleFilter.options(speckle).min_support == 7
  end

  test "nx_segment/3 compiles with EXLA unless told another compiler" do
    assert NxSegment.compute(nx_segment([Stage.Quality], @context)).backend == :exla

    assert NxSegment.compute(nx_segment([Stage.Quality], @context, Nx.Defn.Evaluator)).backend ==
             :evaluator
  end

  test "run_segment/2 returns the segment, which carries what its stages keep to the next pair" do
    segment = nx_segment([{Stage.TemporalFilter, [alpha: 1.0, hold: 1]}], @context)
    matched = Nx.broadcast(Nx.f32(10.0), {12, 16})
    lost = Nx.broadcast(Nx.f32(-1.0), {12, 16})

    {_first, segment} = run_segment(segment, pair(disparity: matched))
    {held, segment} = run_segment(segment, pair(disparity: lost))
    {gone, _segment} = run_segment(segment, pair(disparity: lost))

    assert Nx.to_number(held.disparity[[0, 0]]) == 10.0
    assert Nx.to_number(gone.disparity[[0, 0]]) == -1.0
  end

  test "run_nx/4 runs the pairs, or the fields to put in them, in order through one segment" do
    stages = [{Stage.TemporalFilter, [alpha: 1.0, hold: 1]}]
    matched = Nx.broadcast(Nx.f32(10.0), {12, 16})
    lost = Nx.broadcast(Nx.f32(-1.0), {12, 16})

    inputs = [pair(disparity: matched), %{disparity: lost}, [disparity: lost]]
    [_first, held, gone] = run_nx(stages, @context, inputs)

    assert {Nx.to_number(held.disparity[[0, 0]]), Nx.to_number(gone.disparity[[0, 0]])} ==
             {10.0, -1.0}
  end

  describe "run_stage/5" do
    test "runs a stage alone on Nx, on a pair or on the tensors to put in one" do
      context = %{height: 20, width: 30}
      disparity = blob_disparity()

      from_tensors = run_stage(Stage.MedianFilter, [], context, %{disparity: disparity})
      from_pair = run_stage(Stage.MedianFilter, [], context, pair(disparity: disparity))

      assert Nx.to_number(disparity[[9, 13]]) == 30.0
      assert Nx.to_number(from_tensors.disparity[[9, 13]]) == 10.0
      assert Nx.to_binary(from_pair.disparity) == Nx.to_binary(from_tensors.disparity)
    end

    test "takes the stage's options, and the compiler to run it on" do
      context = %{height: 20, width: 30}
      input = %{disparity: blob_disparity()}

      narrow =
        run_stage(Stage.MedianFilter, [kernel_size: 3], context, input,
          compiler: Nx.Defn.Evaluator
        )

      # A 3x3 window around the blob's centre holds only the blob.
      assert Nx.to_number(narrow.disparity[[9, 13]]) == 30.0
    end

    @tag :stereo_match
    test "runs a stage natively on a Matcher of its own, as many times as it is asked" do
      refute Process.whereis(Matcher)
      context = context(:stereo, 30, 20)
      input = %{disparity: blob_disparity()}

      nx = run_stage(Stage.SpeckleFilter, [], context, input, compiler: Nx.Defn.Evaluator)
      native = run_stage(Stage.SpeckleFilter, [], context, input, backend: :native)
      again = run_stage(Stage.SpeckleFilter, [], context, input, backend: :native)

      assert Nx.to_number(nx.disparity[[9, 13]]) == -1.0
      assert Nx.to_binary(native.disparity) == Nx.to_binary(nx.disparity)
      assert Nx.to_binary(again.disparity) == Nx.to_binary(nx.disparity)
      refute Process.whereis(Matcher)
    end

    test "refuses a native run of a stage that declares no native kind" do
      context = context(:stereo, 32, 24)
      image = texture(24, 32, 1)

      assert_raise ArgumentError, ~r/Decode declares no native kind/, fn ->
        run_stage(Stage.Decode, [], context, frames_pair(image, image), backend: :native)
      end
    end
  end

  describe "run_stage_on_each_backend/5" do
    @tag :stereo_match
    test "runs a stage that declares a native kind on both backends" do
      context = context(:stereo, 30, 20)
      input = %{disparity: blob_disparity()}

      results =
        run_stage_on_each_backend(Stage.SpeckleFilter, [], context, input,
          compiler: Nx.Defn.Evaluator
        )

      assert Map.keys(results) == [:native, :nx]
      assert Nx.to_number(results.nx.disparity[[9, 13]]) == -1.0
      assert Nx.to_binary(results.native.disparity) == Nx.to_binary(results.nx.disparity)
    end

    test "runs a stage that declares none on Nx only" do
      context = context(:stereo, 32, 24)
      image = texture(24, 32, 1)

      results = run_stage_on_each_backend(Stage.Decode, [], context, frames_pair(image, image))

      assert Map.keys(results) == [:nx]
      assert Nx.to_binary(results.nx.left) == Nx.to_binary(image)
    end
  end
end
