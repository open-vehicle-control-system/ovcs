defmodule VisionCore.Stereo.NativeSegmentTest do
  # Each native stage against its Nx stage on the same inputs. Nx's
  # evaluator rounds every f32 operation as IEEE does, so outputs the
  # native code computes in the same order are compared bit for bit; the
  # disparity, too slow on the evaluator, is compared with EXLA.
  use ExUnit.Case, async: false

  import VisionCore.Stereo.TestHelpers,
    only: [
      context: 3,
      context: 4,
      frames_pair: 2,
      members: 2,
      pair: 1,
      run_native: 3,
      stereo_match_path: 0,
      texture: 3
    ]

  alias VisionCore.Stereo.{Matcher, NativeSegment, NxSegment, Pair, Pipeline, Segment, Stage}
  alias VisionCore.Stereo.{TestHelpers, UnknownKind, VehicleDepth}

  @moduletag :stereo_match
  @moduletag :capture_log
  @moduletag timeout: 600_000

  # PointCloud with a range of its own, which the Port is configured with.
  defmodule NearCloud do
    @behaviour VisionCore.Stereo.NxStage

    alias VisionCore.Stereo.Stage.PointCloud

    defdelegate init(opts, context), to: PointCloud
    defdelegate requires(), to: PointCloud
    defdelegate provides(), to: PointCloud
    defdelegate params(state, context), to: PointCloud
    defdelegate step(tensors, params, state), to: PointCloud
    defdelegate finish(pair, outputs, state), to: PointCloud
    defdelegate option_specs(), to: PointCloud
    defdelegate options(state), to: PointCloud
    defdelegate native_settings(state), to: PointCloud
    def native_kind, do: "point_cloud"
    def native_constants, do: %{min_depth_m: 1.0, max_depth_m: 2.0}
  end

  setup do
    start_supervised!({Matcher, path: stereo_match_path()})
    :ok
  end

  # Both cameras turned about their optical axis: rectification leaves black wedges at the edges.
  defp turned(context, degrees) do
    {cos, sin} = {:math.cos(degrees * :math.pi() / 180), :math.sin(degrees * :math.pi() / 180)}
    turn = &%{&1 | rectification_matrix: [cos, -sin, 0.0, sin, cos, 0.0, 0.0, 0.0, 1.0]}

    %{
      context
      | left_calibration: turn.(context.left_calibration),
        right_calibration: turn.(context.right_calibration)
    }
  end

  # On Nx's evaluator, the exact reference, unless a compiler is given.
  defp run_nx(stages, context, pairs, compiler \\ Nx.Defn.Evaluator),
    do: TestHelpers.run_nx(stages, context, pairs, compiler)

  defp run(backend, pair, segment), do: Segment.run(backend, pair, segment, :infinity)

  # Subpixel disparities from 0 to 40, unmatched (-1) on about a fifth of the pixels.
  defp disparity(height, width, seed) do
    key = Nx.Random.key(seed)
    {values, key} = Nx.Random.uniform(key, 0.0, 40.0, shape: {height, width}, type: :f32)
    {holes, _key} = Nx.Random.uniform(key, shape: {height, width}, type: :f32)

    values =
      Nx.select(Nx.less(holes, 0.2), -1.0, Nx.round(Nx.multiply(values, 4)) |> Nx.divide(4))

    Nx.backend_transfer(values, Nx.BinaryBackend)
  end

  defp disparity_pair(disparity), do: pair(disparity: disparity)

  defp assert_same_tensor(got, want, label) do
    assert Nx.shape(got) == Nx.shape(want), "#{label}: shape"
    assert Nx.type(got) == Nx.type(want), "#{label}: type"
    assert Nx.to_binary(got) == Nx.to_binary(want), "#{label}: values differ"
  end

  defp assert_close(got, want, relative, label) when is_number(got) and is_number(want) do
    assert abs(got - want) <= relative * max(abs(want), 1.0),
           "#{label}: #{got} instead of #{want}"
  end

  # EXLA sums the f32 planes in its own order, so the sums agree to about
  # 1e-6 of their size. The spread is the square root of a difference of
  # two such sums of the order of the squared mean: compared as a variance,
  # to that bound.
  defp assert_same_metrics(got, want) do
    assert Enum.map(got, &elem(&1, 0)) == Enum.map(want, &elem(&1, 0))
    got = Map.new(got, fn {name, value, _unit} -> {name, value} end)
    want = Map.new(want, fn {name, value, _unit} -> {name, value} end)

    for {name, value} <- Map.drop(want, [:spread_px]),
        do: assert_close(got[name], value, 1.0e-5, name)

    variance = &(&1 * &1)

    assert abs(variance.(got.spread_px) - variance.(want.spread_px)) <=
             1.0e-5 * variance.(want.mean_disparity_px)
  end

  defp max_ulps(got, want) do
    bits = &for(<<value::little-signed-32 <- Nx.to_binary(&1)>>, do: value)
    bits.(got) |> Enum.zip_with(bits.(want), &abs(&1 - &2)) |> Enum.max()
  end

  defp max_difference(got, want, :u16) do
    values = &for(<<value::little-16 <- &1>>, do: value)
    values.(got) |> Enum.zip_with(values.(want), &abs(&1 - &2)) |> Enum.max()
  end

  describe "Rectification and Sharpness" do
    for {size, frame_size} <- [{{64, 48}, {96, 72}}, {{96, 72}, {96, 72}}, {{40, 30}, {96, 72}}] do
      test "rectify #{inspect(frame_size)} frames to #{inspect(size)} as the Nx stages" do
        {width, height} = unquote(size)
        {frame_width, frame_height} = unquote(frame_size)
        context = context(:distorted, width, height, unquote(frame_size))
        stages = [{Stage.Rectification, []}, {Stage.Sharpness, []}]

        pairs =
          for seed <- 1..2,
              do:
                frames_pair(
                  texture(frame_height, frame_width, seed),
                  texture(frame_height, frame_width, seed + 10)
                )

        for {native, nx} <-
              Enum.zip(run_native(stages, context, pairs), run_nx(stages, context, pairs)) do
          assert_same_tensor(native.left, nx.left, "left")
          assert_same_tensor(native.right, nx.right, "right")

          # Sums of integers, rounded to f32 per column then in total, as the evaluator does.
          assert native.sharpness == nx.sharpness
        end
      end
    end

    test "move the right image by right_row_offset rows, and measure the same sharpness" do
      context = context(:distorted, 64, 48, {96, 72})
      pairs = [frames_pair(texture(72, 96, 3), texture(72, 96, 4))]

      for rows <- [-1.5, 6.5] do
        stages = [{Stage.Rectification, [right_row_offset: rows]}, {Stage.Sharpness, []}]
        [native] = run_native(stages, context, pairs)
        [nx] = run_nx(stages, context, pairs)

        assert_same_tensor(native.left, nx.left, "left")
        assert_same_tensor(native.right, nx.right, "right")
        assert native.sharpness == nx.sharpness
      end
    end

    test "measure the same sharpness beside the black wedges of a turned calibration" do
      context = turned(context(:identity, 64, 48, {96, 72}), 5)
      stages = [{Stage.Rectification, []}, {Stage.Sharpness, []}]
      pairs = [frames_pair(texture(72, 96, 5), texture(72, 96, 6))]

      [native] = run_native(stages, context, pairs)
      [nx] = run_nx(stages, context, pairs)

      assert_same_tensor(native.left, nx.left, "left")
      assert_same_tensor(native.right, nx.right, "right")

      corners =
        for row <- [0, 47], column <- [0, 63], do: Nx.to_number(native.left[[row, column]])

      assert corners == [0, 0, 0, 0]
      assert native.sharpness == nx.sharpness
    end

    test "count the same neighbours on a small image, and none on a black one" do
      context = context(:identity, 5, 3)
      left = Nx.tensor([[10, 13, 0, 7, 9], [0, 0, 4, 4, 200], [255, 1, 0, 0, 3]], type: :u8)
      right = Nx.broadcast(Nx.u8(0), {3, 5})

      pair = %Pair{
        left_frame: nil,
        right_frame: nil,
        left: Nx.backend_transfer(left, Nx.BinaryBackend),
        right: Nx.backend_transfer(right, Nx.BinaryBackend)
      }

      [native] = run_native([{Stage.Sharpness, []}], context, [pair])
      [nx] = run_nx([{Stage.Sharpness, []}], context, [pair])

      assert native.sharpness == nx.sharpness
      assert native.sharpness.left > 0
      assert native.sharpness.right == 0.0
    end
  end

  describe "the disparity filters" do
    for kernel_size <- [3, 5] do
      test "MedianFilter with a #{kernel_size}x#{kernel_size} window" do
        context = context(:stereo, 64, 48)
        stages = [{Stage.MedianFilter, [kernel_size: unquote(kernel_size)]}]
        pairs = [disparity_pair(disparity(48, 64, 1))]

        [native] = run_native(stages, context, pairs)
        [nx] = run_nx(stages, context, pairs)
        assert_same_tensor(native.disparity, nx.disparity, "disparity")
      end
    end

    for opts <- [[], [min_support: 20, max_diff: 0.5], [min_support: 0]] do
      test "SpeckleFilter with #{inspect(opts)}" do
        context = context(:stereo, 64, 48)
        # Smooth patches so neighbours agree, with the holes and noise of a real disparity.
        smooth = Nx.iota({48, 64}, axis: 1) |> Nx.divide(3) |> Nx.as_type(:f32)
        noisy = disparity(48, 64, 2)
        input = Nx.select(Nx.less(Nx.iota({48, 64}, axis: 0), 24), smooth, noisy)
        stages = [{Stage.SpeckleFilter, unquote(opts)}]
        pairs = [disparity_pair(Nx.backend_transfer(input, Nx.BinaryBackend))]

        [native] = run_native(stages, context, pairs)
        [nx] = run_nx(stages, context, pairs)
        assert_same_tensor(native.disparity, nx.disparity, "disparity")
      end
    end

    test "TemporalFilter carries the previous disparity and the missed count across pairs" do
      context = context(:stereo, 64, 48)
      stages = [{Stage.TemporalFilter, [alpha: 0.3, delta: 8.0, hold: 1]}]
      pairs = for seed <- 1..4, do: disparity_pair(disparity(48, 64, seed))

      for {native, nx} <-
            Enum.zip(run_native(stages, context, pairs), run_nx(stages, context, pairs)) do
        assert_same_tensor(native.disparity, nx.disparity, "disparity")
      end
    end

    test "TemporalFilter and Depth read a disparity of 0 as unmatched, pair after pair" do
      context = context(:identity, 192, 108)
      stages = [{Stage.TemporalFilter, []}, {Stage.Depth, []}]
      # Every third pixel flickers between 0 and 1 px; f·B is 12 px·m.
      flickering = Nx.iota({108, 192}) |> Nx.remainder(3) |> Nx.equal(0)

      pairs =
        for {flicker, seed} <- Enum.zip([0.0, 1.0, 0.0, 1.0], 1..4) do
          disparity = Nx.select(flickering, flicker, disparity(108, 192, seed))
          disparity_pair(Nx.backend_transfer(disparity, Nx.BinaryBackend))
        end

      native_pairs = run_native(stages, context, pairs)

      for {native, nx} <- Enum.zip(native_pairs, run_nx(stages, context, pairs)) do
        assert_same_tensor(native.disparity, nx.disparity, "disparity")
        assert native.depth == nx.depth
      end

      flickering_depths =
        for %Pair{depth: <<millimetres::little-16, _::binary>>} <- native_pairs, do: millimetres

      # The first match is held through the next 0, and never blended with one.
      assert flickering_depths == [0, 12_000, 12_000, 12_000]
    end
  end

  describe "the measures" do
    test "RowAlignment sums the same differences per band and offset" do
      context = context(:stereo, 64, 48)
      image = texture(52, 80, 5)
      left = image[[2..49, 0..63]]
      right = image[[0..47, 8..71]]

      pair = %Pair{
        left_frame: nil,
        right_frame: nil,
        left: Nx.backend_transfer(left, Nx.BinaryBackend),
        right: Nx.backend_transfer(right, Nx.BinaryBackend),
        disparity: disparity(48, 64, 6)
      }

      [native] = run_native([{Stage.RowAlignment, []}], context, [pair])
      [nx] = run_nx([{Stage.RowAlignment, []}], context, [pair])

      # Integer sums below 2^24: exact in any order.
      assert native.alignment == nx.alignment
      assert native.metrics == nx.metrics
    end

    test "Quality measures the same share, spread and jitter across pairs" do
      context = context(:stereo, 64, 48)
      pairs = for seed <- 1..3, do: disparity_pair(disparity(48, 64, seed))

      for {native, nx} <-
            Enum.zip(
              run_native([{Stage.Quality, []}], context, pairs),
              run_nx([{Stage.Quality, []}], context, pairs)
            ) do
        assert Enum.map(native.metrics, &elem(&1, 0)) == Enum.map(nx.metrics, &elem(&1, 0))

        # Sums of f32 values accumulated in f64 in another order: the f32 results may differ in the last bit.
        for {{name, got, unit}, {name, want, unit}} <- Enum.zip(native.metrics, nx.metrics),
            do: assert_close(got, want, 1.0e-6, name)
      end
    end
  end

  # 194 × 270 holds 48 × 67 steps of 4, with a remainder each way.
  for {width, height, decimation} <- [{192, 108, 3}, {194, 270, 4}] do
    test "Depth and PointCloud give the same depth and points, #{width}x#{height} every #{decimation}" do
      {width, height} = {unquote(width), unquote(height)}
      context = context(:identity, width, height)
      stages = [{Stage.Depth, []}, {Stage.PointCloud, [decimation: unquote(decimation)]}]
      disparity = disparity(height, width, 7) |> Nx.multiply(8) |> Nx.max(-1.0)
      # Depths beyond 20 m and below 5 cm, which the cloud leaves out.
      disparity = Nx.put_slice(disparity, [0, 0], Nx.tensor([[0.05, 1.0e4, 0.5]]))
      pairs = [disparity_pair(Nx.backend_transfer(disparity, Nx.BinaryBackend))]

      [native] = run_native(stages, context, pairs)
      [nx] = run_nx(stages, context, pairs)

      assert native.depth == nx.depth
      # f·B is about 12 px·m: 0.05 px is beyond what 16-bit millimetres hold, no depth.
      half_pixel_mm = round(context.focal_length_px * context.baseline_m / 0.5 * 1000)
      assert <<0::little-16, 1::little-16, ^half_pixel_mm::little-16, _::binary>> = native.depth
      assert native.disparity_bytes == nx.disparity_bytes
      assert native.cloud_size == nx.cloud_size
      assert native.cloud_points == nx.cloud_points
      assert native.cloud_points > 0

      # NaN points, outside the range, may differ in their bits.
      as_points = &for(<<value::little-float-32 <- &1>>, do: value)
      assert as_points.(native.cloud) == as_points.(nx.cloud)
      assert byte_size(native.cloud) == byte_size(nx.cloud)
    end
  end

  test "Disparity matches as NxStereo.sgm/3" do
    context = context(:stereo, 64, 48)
    image = texture(48, 80, 8)

    pair = %Pair{
      left_frame: nil,
      right_frame: nil,
      left: Nx.backend_transfer(image[[.., 12..75]], Nx.BinaryBackend),
      right: Nx.backend_transfer(image[[.., 0..63]], Nx.BinaryBackend)
    }

    for opts <- [[paths: 3], [paths: 8, num_disparities: 128, p1: 4, p2: 40, uniqueness: 1.2]] do
      [native] = run_native([{Stage.Disparity, opts}], context, [pair])
      [nx] = run_nx([{Stage.Disparity, opts}], context, [pair], EXLA)

      assert_same_tensor(native.disparity, nx.disparity, "disparity #{inspect(opts)}")
      assert native.disparity_range == nx.disparity_range
    end
  end

  test "Disparity reads NxStereo.sgm/3's matches at disparity 0 as unmatched" do
    context = context(:stereo, 64, 48)
    image = texture(48, 76, 9)
    left = image[[.., 0..63]]
    # The upper half the same on both sides, at disparity 0; the lower half at 12.
    right = Nx.concatenate([left[[0..23, ..]], image[[24..47, 12..75]]])

    pair = %Pair{
      left_frame: nil,
      right_frame: nil,
      left: Nx.backend_transfer(left, Nx.BinaryBackend),
      right: Nx.backend_transfer(right, Nx.BinaryBackend)
    }

    [native] = run_native([{Stage.Disparity, [paths: 3]}], context, [pair])
    [nx] = run_nx([{Stage.Disparity, [paths: 3]}], context, [pair], EXLA)

    assert_same_tensor(native.disparity, nx.disparity, "disparity")
    assert Nx.to_number(Nx.any(Nx.equal(native.disparity, 0))) == 0
    share_of = fn pixels -> pixels |> Nx.mean() |> Nx.to_number() end
    assert share_of.(Nx.equal(native.disparity[[0..19, ..]], -1)) > 0.9
    assert share_of.(Nx.greater(native.disparity[[28..47, 16..63]], 0)) > 0.9
  end

  describe "the default stages" do
    defp default_pairs do
      for seed <- 1..3 do
        texture = texture(108, 204, seed)
        frames_pair(texture[[.., 0..191]], texture[[.., 12..203]])
      end
    end

    test "fill the pair as the Nx stages do, pair after pair" do
      context = context(:identity, 192, 108)
      stages = Pipeline.default_stages(disparity: [paths: 3])
      nx_pairs = run_nx(stages, context, default_pairs(), EXLA)
      native_pairs = run_native(stages, context, default_pairs())

      for {{native, nx}, index} <- Enum.with_index(Enum.zip(native_pairs, nx_pairs)) do
        assert_same_tensor(native.left, nx.left, "left")
        assert_same_tensor(native.right, nx.right, "right")

        for field <- [:alignment, :disparity_range, :disparity_scale, :cloud_size, :cloud_points],
            do: assert(Map.fetch!(native, field) == Map.fetch!(nx, field), "#{field} differs")

        assert native.disparity_bytes == Nx.to_binary(native.disparity)
        assert byte_size(native.cloud) == byte_size(nx.cloud)

        # EXLA fuses the temporal filter's blend into a multiply-add: from
        # the second pair, a smoothed disparity may differ in its last bit.
        if index == 0,
          do: assert_same_tensor(native.disparity, nx.disparity, "disparity"),
          else: assert(max_ulps(native.disparity, nx.disparity) <= 1)

        assert max_difference(native.depth, nx.depth, :u16) <= 1

        for side <- [:left, :right],
            do: assert_close(native.sharpness[side], nx.sharpness[side], 1.0e-5, :sharpness)

        assert_same_metrics(native.metrics, nx.metrics)
      end
    end

    test "after the disparity, chained, as the evaluator computes them" do
      context = context(:stereo, 64, 48)
      [_rectification, _sharpness, _disparity | stages] = Pipeline.default_stages()

      pairs =
        for seed <- 1..3 do
          image = texture(52, 80, seed)

          %Pair{
            left_frame: nil,
            right_frame: nil,
            left: Nx.backend_transfer(image[[2..49, 0..63]], Nx.BinaryBackend),
            right: Nx.backend_transfer(image[[0..47, 8..71]], Nx.BinaryBackend),
            disparity: disparity(48, 64, seed)
          }
        end

      for {native, nx} <-
            Enum.zip(run_native(stages, context, pairs), run_nx(stages, context, pairs)) do
        assert_same_tensor(native.disparity, nx.disparity, "disparity")

        for field <- [:depth, :disparity_bytes, :alignment, :cloud_size, :cloud_points],
            do: assert(Map.fetch!(native, field) == Map.fetch!(nx, field), "#{field} differs")

        for {{name, got, unit}, {name, want, unit}} <- Enum.zip(native.metrics, nx.metrics),
            do: assert_close(got, want, 1.0e-6, name)
      end
    end

    test "apply a live setting from the next pair, keeping what they carry" do
      context = context(:stereo, 64, 48)
      stages = [{Stage.SpeckleFilter, []}, {Stage.TemporalFilter, []}]

      [first, second] =
        for seed <- 1..2, do: %{disparity_pair(disparity(48, 64, seed)) | geometry: context}

      {:ok, native} = NativeSegment.build(members(stages, context), context, [])
      {:ok, _pair, native} = run(NativeSegment, first, native)
      {:ok, speckle} = Stage.SpeckleFilter.set_option(hd(native.members).state, :min_support, 0)

      {:ok, native_second, _native} =
        run(NativeSegment, second, NativeSegment.put_member_state(native, 0, speckle))

      {:ok, nx} =
        NxSegment.build(members(stages, context), context,
          defn_options: [compiler: Nx.Defn.Evaluator]
        )

      {:ok, _pair, nx} = run(NxSegment, first, nx)
      nx = NxSegment.put_member_state(nx, 0, speckle)
      {:ok, nx_second, _nx} = run(NxSegment, second, nx)

      assert_same_tensor(native_second.disparity, nx_second.disparity, "disparity")
      [fresh] = run_native(stages, context, [second])
      refute Nx.to_binary(native_second.disparity) == Nx.to_binary(fresh.disparity)
    end

    test "keep what they carry when a live setting changes while a pair is at the device" do
      context = context(:stereo, 64, 48)
      stages = [{Stage.SpeckleFilter, []}, {Stage.TemporalFilter, []}]

      [first, second] =
        for seed <- 1..2, do: %{disparity_pair(disparity(48, 64, seed)) | geometry: context}

      {:ok, native} = NativeSegment.build(members(stages, context), context, [])
      {:ok, speckle} = Stage.SpeckleFilter.set_option(hd(native.members).state, :min_support, 0)
      {:ok, request_id} = NativeSegment.send_request(first, native)
      changed = NativeSegment.put_member_state(native, 0, speckle)
      {:ok, _outputs, replied, _done_ns} = NativeSegment.await(request_id, native, 60_000)

      {:ok, native_second, _native} =
        run(NativeSegment, second, NativeSegment.merge_carry(changed, replied))

      {:ok, nx} =
        NxSegment.build(members(stages, context), context,
          defn_options: [compiler: Nx.Defn.Evaluator]
        )

      {:ok, ticket} = NxSegment.send_request(first, nx)
      changed = NxSegment.put_member_state(nx, 0, speckle)
      {:ok, _outputs, replied, _done_ns} = NxSegment.await(ticket, nx, 60_000)
      {:ok, nx_second, _nx} = run(NxSegment, second, NxSegment.merge_carry(changed, replied))

      assert_same_tensor(native_second.disparity, nx_second.disparity, "disparity")
    end

    test "start over after a calibration reload, and after the Port exits" do
      context = context(:identity, 192, 108)
      stages = [{Stage.TemporalFilter, []}]
      [first, second | _] = for seed <- 1..2, do: disparity_pair(disparity(108, 192, seed))
      {:ok, segment} = NativeSegment.build(members(stages, context), context, [])
      fresh = fn pair -> run_native(stages, context, [pair]) |> hd() end

      {:ok, _pair, segment} = run(NativeSegment, %{first | geometry: context}, segment)
      reloaded = NativeSegment.reload(segment, segment.members, context)
      {:ok, pair, reloaded} = run(NativeSegment, %{second | geometry: context}, reloaded)
      assert Nx.to_binary(pair.disparity) == Nx.to_binary(fresh.(second).disparity)

      {:ok, carried, _segment} = run(NativeSegment, %{first | geometry: context}, reloaded)
      refute Nx.to_binary(carried.disparity) == Nx.to_binary(fresh.(first).disparity)

      %{port: port} = :sys.get_state(Matcher)
      Port.close(port)
      send(Process.whereis(Matcher), {port, {:exit_status, 1}})

      {:ok, pair, _segment} = run(NativeSegment, %{first | geometry: context}, reloaded)
      assert Nx.to_binary(pair.disparity) == Nx.to_binary(fresh.(first).disparity)
    end
  end

  test "take frames of another size as an error, and match the next pair" do
    context = context(:identity, 192, 108)

    {:ok, segment} =
      NativeSegment.build(members([{Stage.Rectification, []}], context), context, [])

    small = frames_pair(texture(48, 64, 1), texture(48, 64, 2))

    assert run(NativeSegment, %{small | geometry: context}, segment) ==
             {:refused, {:frame_size, :left_frame, {48, 64}, {108, 192}}}

    good = frames_pair(texture(108, 192, 1), texture(108, 192, 2))

    assert {:ok, %Pair{left: %Nx.Tensor{shape: {108, 192}}}, _} =
             run(NativeSegment, %{good | geometry: context}, segment)
  end

  test "configures the Port with the constants a stage declares" do
    context = context(:identity, 192, 108)
    disparity = disparity(108, 192, 7) |> Nx.multiply(8) |> Nx.max(-1.0)
    pairs = [disparity_pair(Nx.backend_transfer(disparity, Nx.BinaryBackend))]

    [near] = run_native([{Stage.Depth, []}, {NearCloud, [decimation: 1]}], context, pairs)
    [all] = run_native([{Stage.Depth, []}, {Stage.PointCloud, [decimation: 1]}], context, pairs)

    # NaN, outside the range, is no float: only the kept points match.
    kept =
      for <<_x::float-32-little, _y::float-32-little, z::float-32-little <- near.cloud>>, do: z

    assert length(kept) == near.cloud_points
    assert near.cloud_points > 0 and near.cloud_points < all.cloud_points
    assert Enum.all?(kept, &(&1 > 1.0 and &1 < 2.0))
  end

  test "stops at a configuration the Port refuses, saying why" do
    context = context(:stereo, 64, 48)
    pair = %{disparity_pair(disparity(48, 64, 1)) | geometry: context}
    stages = [{Stage.TemporalFilter, []}, {UnknownKind, []}]
    {:ok, segment} = NativeSegment.build(members(stages, context), context, [])

    assert run(NativeSegment, pair, segment) ==
             {:stop, "no native implementation of no_such_stage"}
  end

  test "refuses frames smaller than the working size to rectify, as the Nx stage does" do
    context = context(:identity, 64, 48)
    small = %{context | frame_width: 48, frame_height: 36}
    members = members([{Stage.Rectification, []}], context)
    {:ok, segment} = NativeSegment.build(members, small, [])
    pair = %{frames_pair(texture(36, 48, 1), texture(36, 48, 2)) | geometry: small}

    assert run(NativeSegment, pair, segment) ==
             {:stop,
              "rectification only shrinks: 48x36 frames are smaller than the 64x48 working size"}
  end

  test "takes the stages that declare a native kind, to compute natively" do
    declared = [{Stage.MedianFilter, []}, {VehicleDepth, []}]

    for member <- members(declared ++ Pipeline.default_stages(), context(:identity, 64, 48)) do
      assert NativeSegment.accepts?(member.module, member.state, :native)
      refute NativeSegment.accepts?(member.module, member.state, :nx)
    end

    refute NativeSegment.accepts?(Stage.Decode, nil, :native)
  end

  test "computes a vehicle's stage as the core stage of the kind it declares" do
    context = context(:identity, 64, 48)
    pairs = [disparity_pair(disparity(48, 64, 3))]

    [native] = run_native([{VehicleDepth, []}], context, pairs)
    [nx] = run_nx([{Stage.Depth, []}], context, pairs)

    assert native.depth == nx.depth
    assert native.disparity_bytes == nx.disparity_bytes
  end

  test "sends its pairs to the matcher its build options name" do
    path = stereo_match_path()
    start_supervised!({Matcher, name: :segment_matcher, path: path}, id: :segment_matcher)
    stop_supervised!(Matcher)

    context = context(:stereo, 64, 48)
    pair = %{disparity_pair(disparity(48, 64, 1)) | geometry: context}
    members = members([{Stage.TemporalFilter, []}], context)
    {:ok, segment} = NativeSegment.build(members, context, matcher: :segment_matcher)

    assert {:ok, %Pair{disparity: %Nx.Tensor{}}, _segment} = run(NativeSegment, pair, segment)
  end

  test "waits for a pair's outputs up to a timeout" do
    context = context(:stereo, 64, 48)
    stages = [{Stage.TemporalFilter, []}]
    pair = %{disparity_pair(disparity(48, 64, 1)) | geometry: context}
    {:ok, segment} = NativeSegment.build(members(stages, context), context, [])

    {:ok, request_id} = NativeSegment.send_request(pair, segment)

    assert {:ok, %{disparity: disparity}, _segment, _done_ns} =
             NativeSegment.await(request_id, segment, 60_000)

    [fresh] = run_native(stages, context, [pair])
    assert_same_tensor(disparity, fresh.disparity, "disparity")
  end
end
