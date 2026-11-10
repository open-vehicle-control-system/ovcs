defmodule VisionCore.Stereo.GpuTest do
  # The stages on a Vulkan GPU against their Nx code on EXLA; nx_stereo tests each kernel.
  use ExUnit.Case, async: false

  import VisionCore.Stereo.TestHelpers, only: [context: 4, frames_pair: 2, members: 2, texture: 3]

  alias VisionCore.Stereo.{NxSegment, Segment, Stage}

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

  # The share of the elements of two f32 tensors within `relative` of each other, NaN matching NaN.
  defp close(got, want, relative) do
    nan = Nx.logical_and(Nx.is_nan(got), Nx.is_nan(want))
    error = Nx.abs(Nx.subtract(got, want))
    near = Nx.less_equal(error, Nx.multiply(Nx.abs(want), relative))
    nan |> Nx.logical_or(near) |> Nx.mean() |> Nx.to_number()
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
