defmodule VisionCore.Stereo.KernelsTest do
  use ExUnit.Case, async: false

  import VisionCore.Stereo.TestHelpers, only: [context: 4, frames_pair: 2, members: 2, texture: 3]

  alias VisionCore.Stereo.{Kernels, NxSegment, Packing, Segment, Stage}

  @moduletag :vulkan
  @moduletag :tmp_dir

  defp vulkan_options(dir, packed?) do
    {:ok, [device | _]} = NxIREE.list_devices("vulkan")

    [
      compiler: NxIREE.Compiler,
      iree_module_cache: dir,
      iree_runtime_options: [device: device],
      byte_storage: not packed?
    ]
  end

  defp run(stages, context, pair, defn_options) do
    {:ok, segment} =
      NxSegment.build(members(stages, context), context, defn_options: defn_options)

    {:ok, pair, _segment} =
      Segment.run(NxSegment, %{pair | geometry: context}, segment, :infinity)

    pair
  end

  # The share of pixels within `tolerance` of the reference: the GPU may
  # round a sample that falls on a half differently.
  defp within(image, reference, tolerance) do
    image
    |> Nx.as_type(:s32)
    |> Nx.subtract(Nx.as_type(reference, :s32))
    |> Nx.abs()
    |> Nx.less_equal(tolerance)
    |> Nx.mean()
    |> Nx.to_number()
  end

  describe "rectification" do
    setup do
      context = context(:distorted, 364, 272, {728, 544})
      left = texture(544, 728, 1)
      right = texture(544, 728, 2)
      %{context: context, pair: frames_pair(left, right)}
    end

    for packed? <- [true, false] do
      test "the kernel samples as NxStereo.Rectify does, packed: #{packed?}", %{
        context: context,
        pair: pair,
        tmp_dir: dir
      } do
        reference = run([Stage.Rectification], context, pair, compiler: EXLA)
        frame = Nx.from_binary(pair.left_frame.grey, :u8) |> Nx.reshape({544, 728})
        frame = if unquote(packed?), do: Packing.pack(Nx.to_binary(frame), 728, 544), else: frame
        %{left: camera} = Stage.Rectification.params(%{right_row_offset: 0.0}, context)

        # The default function gives zeros: only the kernel gives the image.
        rectify = fn frame, camera ->
          Kernels.rectify(frame, camera, {272, 364}, fn _frame, _camera ->
            if unquote(packed?),
              do:
                {Nx.broadcast(0, {272, 364}) |> Nx.as_type(:s32),
                 Nx.broadcast(0, {272, 91}) |> Nx.as_type(:u32)},
              else: Nx.broadcast(0, {272, 364}) |> Nx.as_type(:u8)
          end)
        end

        options = vulkan_options(dir, unquote(packed?)) |> Keyword.delete(:byte_storage)

        result =
          Nx.Defn.jit(rectify, options).(frame, Kernels.camera_vector(camera))
          |> Nx.backend_transfer()

        if unquote(packed?) do
          {image, words} = result
          assert within(image, reference.left, 1) >= 0.999
          assert Packing.unpack_download(words) |> Nx.as_type(:s32) == image
        else
          assert within(result, reference.left, 1) >= 0.999
        end
      end

      test "the stage on the GPU gives its Nx images, packed: #{packed?}", %{
        context: context,
        pair: pair,
        tmp_dir: dir
      } do
        reference = run([Stage.Rectification], context, pair, compiler: EXLA)
        gpu = run([Stage.Rectification], context, pair, vulkan_options(dir, unquote(packed?)))

        assert Nx.type(gpu.left) == {:u, 8}
        assert within(gpu.left, reference.left, 1) >= 0.999
        assert within(gpu.right, reference.right, 1) >= 0.999
      end
    end
  end

  describe "sharpness" do
    setup do
      context = context(:identity, 364, 272, nil)
      # Black borders, as rectification leaves, and texture inside.
      left = texture(272, 364, 3) |> Nx.put_slice([0, 0], Nx.broadcast(Nx.u8(0), {272, 10}))
      right = texture(272, 364, 4) |> Nx.max(1)
      %{context: context, left: left, right: right}
    end

    for packed? <- [true, false] do
      test "the kernel sums as the Nx step does, packed: #{packed?}", %{
        left: left,
        right: right,
        tmp_dir: dir
      } do
        type = if unquote(packed?), do: :s32, else: :u8
        [left, right] = Enum.map([left, right], &Nx.as_type(&1, type))
        reference = Stage.Sharpness.step(%{left: left, right: right}, %{}, nil).sharpness_sums

        sums = fn left, right ->
          Kernels.sharpness(left, right, fn _left, _right -> Nx.broadcast(Nx.f32(0), {6}) end)
        end

        options = vulkan_options(dir, unquote(packed?)) |> Keyword.delete(:byte_storage)
        result = Nx.Defn.jit(sums, options).(left, right) |> Nx.backend_transfer()

        for {got, want} <- Enum.zip(Nx.to_flat_list(result), Nx.to_flat_list(reference)) do
          assert_in_delta got, want, abs(want) * 1.0e-5
        end
      end
    end
  end

  # Runs `fun` compiled for the Vulkan device on `args`.
  defp on_gpu(fun, args, dir) do
    options = dir |> vulkan_options(true) |> Keyword.delete(:byte_storage)
    fun |> Nx.Defn.jit(options) |> apply(args) |> Nx.backend_transfer()
  end

  # A disparity of slanted surfaces, with holes and isolated wrong pixels.
  defp disparity(height, width, seed) do
    key = Nx.Random.key(seed)
    {noise, key} = Nx.Random.uniform(key, shape: {height, width})
    {wrong, _key} = Nx.Random.uniform(key, 0.0, 128.0, shape: {height, width})
    surface = Nx.add(Nx.iota({height, width}, axis: 1) |> Nx.divide(width / 30), 4.0)
    surface = Nx.select(Nx.less(noise, 0.05), wrong, surface)
    Nx.select(Nx.greater(noise, 0.9), -1.0, surface) |> Nx.as_type(:f32)
  end

  test "the speckle kernel keeps the pixels the Nx step keeps", %{tmp_dir: dir} do
    disparity = disparity(272, 364, 5)
    params = %{min_support: 12, max_diff: 1.0}
    reference = Stage.SpeckleFilter.step(%{disparity: disparity}, params, nil).disparity

    despeckle = fn disparity, min_support, max_diff ->
      Kernels.despeckle(disparity, min_support, max_diff, fn disparity, _min, _max ->
        Nx.broadcast(Nx.f32(0), Nx.shape(disparity))
      end)
    end

    assert on_gpu(despeckle, [disparity, Nx.s32(12), Nx.f32(1.0)], dir) == reference
  end

  for packed? <- [true, false] do
    test "the row alignment kernel sums as the Nx step does, packed: #{packed?}", %{tmp_dir: dir} do
      type = if unquote(packed?), do: :s32, else: :u8
      right = texture(272, 364, 6)
      # The left image is the right one 4 pixels further, one row lower.
      left = right |> Nx.pad(0, [{1, 0, 0}, {0, 4, 0}]) |> Nx.slice([0, 4], [272, 364])
      disparity = disparity(272, 364, 7)
      [left, right] = Enum.map([left, right], &Nx.as_type(&1, type))
      tensors = %{left: left, right: right, disparity: disparity}
      reference = Stage.RowAlignment.step(tensors, %{}, nil).alignment_sums

      sums = fn left, right, disparity ->
        Kernels.row_alignment(left, right, disparity, fn _left, _right, _disparity ->
          Nx.broadcast(Nx.f32(0), {4, 6})
        end)
      end

      assert on_gpu(sums, [left, right, disparity], dir) == reference
    end
  end

  test "the temporal kernel filters and counts misses as the Nx step does", %{tmp_dir: dir} do
    current = disparity(272, 364, 8)
    {jitter, _key} = Nx.Random.uniform(Nx.Random.key(9), -3.0, 3.0, shape: {272, 364})
    previous = Nx.select(Nx.greater(jitter, 2.5), -1.0, Nx.add(disparity(272, 364, 10), jitter))
    {missed, _key} = Nx.Random.randint(Nx.Random.key(11), 0, 4, shape: {272, 364}, type: :s32)
    missed = Nx.as_type(missed, :f32)

    params = %{
      alpha: Nx.f32(0.4),
      delta: Nx.f32(2.0),
      hold: Nx.s32(2),
      previous: previous,
      missed: missed
    }

    reference = Stage.TemporalFilter.step(%{disparity: current}, params, nil)

    filter = fn current, previous, missed, alpha, delta, hold ->
      Kernels.temporal_filter(current, previous, missed, [alpha, delta, hold], fn current,
                                                                                  _previous,
                                                                                  missed,
                                                                                  _settings ->
        {current, missed}
      end)
    end

    args = [current, previous, missed, params.alpha, params.delta, params.hold]
    {filtered, missed} = on_gpu(filter, args, dir)
    assert filtered == reference.disparity
    assert missed == reference[{:carry, :missed}]
  end

  # The share of the elements of two f32 tensors within `relative` of each other, NaN matching NaN.
  defp close(got, want, relative) do
    nan = Nx.logical_and(Nx.is_nan(got), Nx.is_nan(want))
    error = Nx.abs(Nx.subtract(got, want))
    near = Nx.less_equal(error, Nx.multiply(Nx.abs(want), relative))
    nan |> Nx.logical_or(near) |> Nx.mean() |> Nx.to_number()
  end

  test "the depth kernel measures f·B/d as the Nx step does", %{tmp_dir: dir} do
    # Down to 0.001 px, whose depth is beyond 16-bit millimetres.
    disparity = disparity(272, 364, 12) |> Nx.put_slice([0, 0], Nx.tensor([[0.001, 0.0]]))
    params = %{focal_length_px: Nx.f32(436.5), baseline_m: Nx.f32(0.2)}
    reference = Stage.Depth.step(%{disparity: disparity}, params, nil)

    depth = fn disparity, f, b ->
      Kernels.depth(disparity, f, b, fn disparity, _f, _b ->
        {Nx.broadcast(Nx.u16(0), Nx.shape(disparity)),
         Nx.broadcast(Nx.f32(0), Nx.shape(disparity))}
      end)
    end

    {mm, m} = on_gpu(depth, [disparity, params.focal_length_px, params.baseline_m], dir)
    assert close(m, reference.depth_m, 1.0e-6) == 1.0
    difference = Nx.abs(Nx.subtract(Nx.as_type(mm, :s32), Nx.as_type(reference.depth_mm, :s32)))
    assert Nx.to_number(Nx.reduce_max(difference)) <= 1
    assert Nx.to_number(Nx.mean(Nx.greater(difference, 0))) < 0.001
    assert Nx.to_number(mm[0][0]) == 0
  end

  test "the point cloud kernel unprojects and counts as the Nx step does", %{tmp_dir: dir} do
    depth_m = disparity(272, 364, 13) |> Nx.divide(5) |> Nx.max(0.0)
    params = %{focal_length_px: Nx.f32(436.5), cx: Nx.f32(181.5), cy: Nx.f32(135.5)}
    reference = Stage.PointCloud.step(%{depth_m: depth_m}, params, 4)

    cloud = fn depth_m, f, cx, cy ->
      Kernels.point_cloud(depth_m, [f, cx, cy], 4, fn _depth_m, _settings ->
        {Nx.broadcast(Nx.f32(0), {68, 91, 3}), Nx.f32(0)}
      end)
    end

    {grid, kept} = on_gpu(cloud, [depth_m, params.focal_length_px, params.cx, params.cy], dir)
    assert close(grid, reference.cloud_grid, 1.0e-6) == 1.0
    assert Nx.to_number(kept) == Nx.to_number(reference.cloud_points)
  end

  test "the quality kernel sums as the Nx step does", %{tmp_dir: dir} do
    current = disparity(272, 364, 14)
    previous = disparity(272, 364, 15)
    reference = Stage.Quality.step(%{disparity: current}, %{previous: previous}, nil).quality_sums

    sums = fn current, previous ->
      Kernels.quality(current, previous, fn _current, _previous ->
        Nx.broadcast(Nx.f32(0), {5})
      end)
    end

    assert close(on_gpu(sums, [current, previous], dir), reference, 1.0e-4) == 1.0
  end

  # EXLA's reference at 728x544 with 128 disparities is slow on a loaded host.
  @tag timeout: 300_000
  test "a pipeline's published outputs come back from the GPU as its Nx steps give them", %{
    tmp_dir: dir
  } do
    context = context(:identity, 728, 544, nil)
    left = texture(544, 728, 16)
    right = left |> Nx.pad(0, [{0, 0, 0}, {0, 9, 0}]) |> Nx.slice([0, 9], [544, 728])
    pair = frames_pair(left, right)
    stages = VisionCore.Stereo.Pipeline.default_stages(disparity: [num_disparities: 128])

    reference = run(stages, context, pair, compiler: EXLA)
    gpu = run(stages, context, pair, vulkan_options(dir, true))

    # Subpixel values may differ in their last bits: a GPU's division is not correctly rounded.
    assert close(gpu.disparity, reference.disparity, 1.0e-5) >= 0.999
    assert gpu.left == reference.left
  end

  @tag timeout: 300_000
  test "a pipeline searching coarse to fine on the GPU gives its Nx steps' matches", %{
    tmp_dir: dir
  } do
    context = context(:identity, 728, 544, nil)
    left = texture(544, 728, 17)
    right = left |> Nx.pad(0, [{0, 0, 0}, {0, 41, 0}]) |> Nx.slice([0, 41], [544, 728])
    pair = frames_pair(left, right)

    stages =
      VisionCore.Stereo.Pipeline.default_stages(
        disparity: [num_disparities: 128, search: "coarse_to_fine"]
      )

    reference = run(stages, context, pair, compiler: EXLA)
    gpu = run(stages, context, pair, vulkan_options(dir, true))

    assert close(gpu.disparity, reference.disparity, 1.0e-5) >= 0.999
    assert Nx.to_number(Nx.mean(Nx.greater(gpu.disparity, 40.5))) > 0.8
  end
end

defmodule VisionCore.Stereo.KernelsSizesTest do
  use ExUnit.Case, async: true

  alias VisionCore.Stereo.Kernels

  test "rectification refuses a packed frame to a width that is not a multiple of 4" do
    rectify = fn frame, camera ->
      Kernels.rectify(frame, camera, {272, 362}, fn _frame, _camera ->
        {Nx.broadcast(Nx.s32(0), {272, 362}), Nx.broadcast(Nx.u32(0), {272, 90})}
      end)
    end

    assert_raise ArgumentError, ~r/multiple of 4/, fn ->
      Nx.Defn.jit(rectify).(Nx.broadcast(Nx.u32(0), {544, 182}), Nx.broadcast(Nx.f32(0), {23}))
    end
  end

  test "rectification of an 8-bit frame to another width runs the default" do
    rectify = fn frame, camera ->
      Kernels.rectify(frame, camera, {272, 362}, fn _frame, _camera ->
        Nx.broadcast(Nx.u8(7), {272, 362})
      end)
    end

    image =
      Nx.Defn.jit(rectify).(Nx.broadcast(Nx.u8(0), {544, 728}), Nx.broadcast(Nx.f32(0), {23}))

    assert image == Nx.broadcast(Nx.u8(7), {272, 362})
  end

  test "depth of an odd number of pixels runs the default" do
    depth = fn disparity, f, b ->
      Kernels.depth(disparity, f, b, fn disparity, _f, _b ->
        {Nx.as_type(disparity, :u16), disparity}
      end)
    end

    {depth_mm, depth_m} =
      Nx.Defn.jit(depth).(Nx.broadcast(Nx.f32(3), {3, 5}), Nx.f32(400), Nx.f32(0.2))

    assert depth_mm == Nx.broadcast(Nx.u16(3), {3, 5})
    assert depth_m == Nx.broadcast(Nx.f32(3), {3, 5})
  end
end
