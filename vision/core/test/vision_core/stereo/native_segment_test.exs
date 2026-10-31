defmodule VisionCore.Stereo.NativeSegmentTest do
  # Each native stage against its Nx stage on the same inputs. Nx's
  # evaluator rounds every f32 operation as IEEE does, so outputs the
  # native code computes in the same order are compared bit for bit; the
  # disparity, too slow on the evaluator, is compared with EXLA.
  use ExUnit.Case, async: false

  alias VisionCore.Camera.Frame
  alias VisionCore.Stereo.{Matcher, NativeSegment, NxSegment, Pair, Pipeline, Stage}

  @moduletag :stereo_match
  @moduletag :capture_log
  @moduletag timeout: 600_000

  @calibration Path.expand("../../support/calibration", __DIR__)

  setup do
    start_supervised!(Matcher)
    :ok
  end

  defp context(calibration, width, height, frame_size \\ nil) do
    {frame_width, frame_height} = frame_size || {width, height}

    Pipeline.context(
      left_calibration_path: Path.join(@calibration, "#{calibration}_left.yaml"),
      right_calibration_path: Path.join(@calibration, "#{calibration}_right.yaml"),
      width: width,
      height: height,
      frame_width: frame_width,
      frame_height: frame_height
    )
  end

  defp members(stages, context) do
    for {module, opts} <- stages do
      {:ok, state} = module.init(opts, context)
      %{module: module, name: module, state: state}
    end
  end

  # Every pair through one segment, in order, so carried values flow.
  defp run_nx(stages, context, pairs, compiler \\ Nx.Defn.Evaluator) do
    {:ok, segment} = NxSegment.build(members(stages, context), context, compiler: compiler)
    run_all(&NxSegment.run/2, segment, context, pairs)
  end

  defp run_native(stages, context, pairs) do
    {:ok, segment} = NativeSegment.build(members(stages, context), context)
    run_all(&NativeSegment.run/2, segment, context, pairs)
  end

  defp run_all(run, segment, context, pairs) do
    {pairs, _segment} =
      Enum.map_reduce(pairs, segment, fn pair, segment ->
        {:ok, pair, segment} = run.(%{pair | geometry: context}, segment)
        {pair, segment}
      end)

    pairs
  end

  defp frame(image) do
    {height, width} = Nx.shape(image)
    %Frame{label: "left", grey: Nx.to_binary(image), width: width, height: height, capture_ns: 0}
  end

  defp frames_pair(left, right), do: %Pair{left_frame: frame(left), right_frame: frame(right)}

  defp texture(height, width, seed) do
    {texture, _key} =
      Nx.Random.randint(Nx.Random.key(seed), 0, 256, shape: {height, width}, type: :s32)

    Nx.as_type(texture, :u8)
  end

  # Subpixel disparities from 0 to 40, unmatched (-1) on about a fifth of the pixels.
  defp disparity(height, width, seed) do
    key = Nx.Random.key(seed)
    {values, key} = Nx.Random.uniform(key, 0.0, 40.0, shape: {height, width}, type: :f32)
    {holes, _key} = Nx.Random.uniform(key, shape: {height, width}, type: :f32)

    values =
      Nx.select(Nx.less(holes, 0.2), -1.0, Nx.round(Nx.multiply(values, 4)) |> Nx.divide(4))

    Nx.backend_transfer(values, Nx.BinaryBackend)
  end

  defp disparity_pair(disparity),
    do: %Pair{left_frame: nil, right_frame: nil, disparity: disparity}

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

    for {name, value} <- Map.drop(want, [:std_disp]),
        do: assert_close(got[name], value, 1.0e-5, name)

    variance = &(&1 * &1)

    assert abs(variance.(got.std_disp) - variance.(want.std_disp)) <=
             1.0e-5 * variance.(want.mean_disp)
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

    test "move the right image by right_row_offset rows" do
      context = context(:distorted, 64, 48, {96, 72})
      pairs = [frames_pair(texture(72, 96, 3), texture(72, 96, 4))]
      stages = [{Stage.Rectification, [right_row_offset: -1.5]}]

      [native] = run_native(stages, context, pairs)
      [nx] = run_nx(stages, context, pairs)

      assert_same_tensor(native.left, nx.left, "left")
      assert_same_tensor(native.right, nx.right, "right")
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
      stages = [{Stage.TemporalFilter, [alpha: 0.3, delta: 30.0, hold: 1]}]
      pairs = for seed <- 1..4, do: disparity_pair(disparity(48, 64, seed))

      for {native, nx} <-
            Enum.zip(run_native(stages, context, pairs), run_nx(stages, context, pairs)) do
        assert_same_tensor(native.disparity, nx.disparity, "disparity")
      end
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

  test "Depth and PointCloud give the same depth and points" do
    context = context(:identity, 192, 108)
    stages = [{Stage.Depth, []}, {Stage.PointCloud, [decimation: 3]}]
    disparity = disparity(108, 192, 7) |> Nx.multiply(8) |> Nx.max(-1.0)
    # Depths beyond 20 m and below 5 cm, which the cloud leaves out.
    disparity = Nx.put_slice(disparity, [0, 0], Nx.tensor([[0.05, 1.0e4, 0.5]]))
    pairs = [disparity_pair(Nx.backend_transfer(disparity, Nx.BinaryBackend))]

    [native] = run_native(stages, context, pairs)
    [nx] = run_nx(stages, context, pairs)

    assert native.depth == nx.depth
    assert native.disparity_bytes == nx.disparity_bytes
    assert_same_tensor(native.depth_m, nx.depth_m, "depth_m")
    assert native.cloud_size == nx.cloud_size
    assert native.cloud_points == nx.cloud_points
    assert native.cloud_points > 0

    # NaN points, outside the range, may differ in their bits.
    as_points = &for(<<value::little-float-32 <- &1>>, do: value)
    assert as_points.(native.cloud) == as_points.(nx.cloud)
    assert byte_size(native.cloud) == byte_size(nx.cloud)
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

        assert max_ulps(native.depth_m, nx.depth_m) <= 2
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
        assert_same_tensor(native.depth_m, nx.depth_m, "depth_m")

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

      {:ok, native} = NativeSegment.build(members(stages, context), context)
      {:ok, _pair, native} = NativeSegment.run(first, native)
      {:ok, speckle} = Stage.SpeckleFilter.set_option(hd(native.members).state, :min_support, 0)

      {:ok, native_second, _native} =
        NativeSegment.run(second, NativeSegment.put_member_state(native, 0, speckle))

      # The Nx segment starts its carried values over on a new setting: they are put back.
      {:ok, nx} = NxSegment.build(members(stages, context), context, compiler: Nx.Defn.Evaluator)
      {:ok, _pair, nx} = NxSegment.run(first, nx)
      carried = Map.take(nx.params[1], [:previous, :missed])
      nx = NxSegment.put_member_state(nx, 0, speckle)
      nx = %{nx | params: Map.update!(nx.params, 1, &Map.merge(&1, carried))}
      {:ok, nx_second, _nx} = NxSegment.run(second, nx)

      assert_same_tensor(native_second.disparity, nx_second.disparity, "disparity")
      [fresh] = run_native(stages, context, [second])
      refute Nx.to_binary(native_second.disparity) == Nx.to_binary(fresh.disparity)
    end

    test "start over after a calibration reload, and after the Port exits" do
      context = context(:identity, 192, 108)
      stages = [{Stage.TemporalFilter, []}]
      [first, second | _] = for seed <- 1..2, do: disparity_pair(disparity(108, 192, seed))
      {:ok, segment} = NativeSegment.build(members(stages, context), context)
      fresh = fn pair -> run_native(stages, context, [pair]) |> hd() end

      {:ok, _pair, segment} = NativeSegment.run(%{first | geometry: context}, segment)
      reloaded = NativeSegment.reload(segment, segment.members, context)
      {:ok, pair, reloaded} = NativeSegment.run(%{second | geometry: context}, reloaded)
      assert Nx.to_binary(pair.disparity) == Nx.to_binary(fresh.(second).disparity)

      {:ok, carried, _segment} = NativeSegment.run(%{first | geometry: context}, reloaded)
      refute Nx.to_binary(carried.disparity) == Nx.to_binary(fresh.(first).disparity)

      %{port: port} = :sys.get_state(Matcher)
      Port.close(port)
      send(Process.whereis(Matcher), {port, {:exit_status, 1}})

      {:ok, pair, _segment} = NativeSegment.run(%{first | geometry: context}, reloaded)
      assert Nx.to_binary(pair.disparity) == Nx.to_binary(fresh.(first).disparity)
    end
  end

  test "take frames of another size as an error, and match the next pair" do
    context = context(:identity, 192, 108)
    {:ok, segment} = NativeSegment.build(members([{Stage.Rectification, []}], context), context)
    small = frames_pair(texture(48, 64, 1), texture(48, 64, 2))

    assert {:error, {:frame_size, :left_frame, {48, 64}, {108, 192}}, segment} =
             NativeSegment.run(%{small | geometry: context}, segment)

    good = frames_pair(texture(108, 192, 1), texture(108, 192, 2))

    assert {:ok, %Pair{left: %Nx.Tensor{shape: {108, 192}}}, _} =
             NativeSegment.run(%{good | geometry: context}, segment)
  end

  test "says which stages have a native implementation" do
    for {module, _opts} <- Pipeline.default_stages(), do: assert(NativeSegment.supported?(module))
    refute NativeSegment.supported?(Stage.Decode)
  end
end
