defmodule VisionCore.Stereo.Kernels do
  @moduledoc """
  The stereo stages' hand-written Vulkan compute kernels, as `Nx.block/4`s.

  A function compiled by `NxIREE.Compiler` for Vulkan runs a block as its
  kernels, which read and write 32-bit words only; everywhere else, as on
  EXLA, the block runs the default function the stage gives, its Nx code,
  which is the reference the kernels are tested against. On a GPU without
  8-bit storage, such as the Adreno of the Arduino VENTUNO Q, the
  kernels avoid IREE's emulation of 8-bit buffers, which gives wrong
  results there.

  The GLSL sources are in `shaders/`; `mix vision_core.shaders` compiles
  them into `priv/spirv`.
  """

  alias NxIREE.Vulkan.{Kernel, Pipeline}

  @spirv_dir Path.expand("../../../priv/spirv", __DIR__)

  # Each kernel's GLSL source in shaders/ and its macros, for `mix vision_core.shaders`.
  @variants [
    rectify_words: {"rectify", ["-DWORDS=1"]},
    rectify_bytes: {"rectify", ["-DWORDS=0"]},
    sharpness_rows_words: {"sharpness_rows", ["-DWORDS=1"]},
    sharpness_rows_bytes: {"sharpness_rows", ["-DWORDS=0"]},
    column_sums: {"column_sums", []},
    despeckle: {"despeckle", []},
    row_alignment_rows_words: {"row_alignment_rows", ["-DWORDS=1"]},
    row_alignment_rows_bytes: {"row_alignment_rows", ["-DWORDS=0"]},
    temporal_filter: {"temporal_filter", []},
    depth: {"depth", []},
    point_cloud_rows: {"point_cloud_rows", []},
    quality_rows: {"quality_rows", []}
  ]

  @spirv (for {kernel, _source} <- @variants, into: %{} do
            path = Path.join(@spirv_dir, "#{kernel}.spv")
            @external_resource path
            {kernel, File.read!(path)}
          end)

  @group 64

  @doc false
  def variants, do: @variants

  @doc """
  The `f32` vector of `camera`, an `NxStereo.Rectify.camera/4` map, that
  `rectify/4` takes: `k`, `d` and `inverse_pr`, row-major.
  """
  @spec camera_vector(NxStereo.Rectify.camera()) :: Nx.Tensor.t()
  def camera_vector(camera) do
    Nx.concatenate([Nx.flatten(camera.k), camera.d, Nx.flatten(camera.inverse_pr)])
  end

  @doc """
  The camera map `camera_vector/1` flattened.
  """
  @spec camera_map(Nx.Tensor.t()) :: NxStereo.Rectify.camera()
  def camera_map(vector) do
    %{
      k: vector |> Nx.slice([0], [9]) |> Nx.reshape({3, 3}),
      d: Nx.slice(vector, [9], [5]),
      inverse_pr: vector |> Nx.slice([14], [9]) |> Nx.reshape({3, 3})
    }
  end

  @doc """
  `frame` rectified to `{height, width}` by the camera `vector`, as
  `NxStereo.Rectify.rectify/3` does: the `u8` image of a `u8` frame, or,
  of a frame packed as `u32` words (`VisionCore.Stereo.Packing`), the
  `s32` image and its packed `u32` words. `default` takes the frame and
  the vector and gives the same off Vulkan. The kernel writes 4 pixels
  per word: a `u8` frame rectified to another width runs `default`, a
  packed one raises.
  """
  @spec rectify(Nx.Tensor.t(), Nx.Tensor.t(), {pos_integer(), pos_integer()}, function()) ::
          Nx.Tensor.t() | {Nx.Tensor.t(), Nx.Tensor.t()}
  def rectify(frame, vector, {_height, width} = size, default) do
    words? = Nx.type(frame) == {:u, 32}

    cond do
      rem(width, 4) == 0 ->
        rectify_kernel(frame, vector, size, words?, default)

      words? ->
        raise ArgumentError,
              "rectifying packed frames needs a width that is a multiple of 4, got #{width}"

      true ->
        default.(frame, vector)
    end
  end

  defp rectify_kernel(frame, vector, {height, width}, words?, default) do
    {frame_height, row} = Nx.shape(frame)
    frame_width = if words?, do: row * 4, else: row
    packed = Nx.template({height, div(width, 4)}, :u32)

    outputs =
      if words?,
        do: [image: Nx.template({height, width}, :s32), packed: packed],
        else: [packed: Nx.template({height, width}, :u8)]

    kernel = %Kernel{
      spirv: Map.fetch!(@spirv, if(words?, do: :rectify_words, else: :rectify_bytes)),
      workgroups: {ceil_div(div(width, 4), @group), height, 1},
      specialization: %{
        0 => frame_width,
        1 => frame_height,
        2 => width,
        3 => height,
        4 => frame_width / width,
        5 => frame_height / height
      }
    }

    pipeline = %Pipeline{
      inputs: [:frame, :camera],
      stages: [{kernel, [:frame, :camera], outputs}],
      outputs: Keyword.keys(outputs)
    }

    template =
      case Keyword.values(outputs) do
        [image, packed] -> {image, packed}
        [image] -> image
      end

    Nx.block(pipeline, [frame, vector], template, fn _pipeline, frame, vector ->
      default.(frame, vector)
    end)
  end

  @doc """
  `Stage.Sharpness`'s six sums of the `left` and `right` images: per
  image, the squared differences, the greys and the number of the pairs
  of horizontal neighbours both above black, as `[left energy, right
  energy, left grey, right grey, left pairs, right pairs]`. The images
  are both `u8`, or both `s32`. `default` takes the images and gives the
  same off Vulkan.
  """
  @spec sharpness(Nx.Tensor.t(), Nx.Tensor.t(), function()) :: Nx.Tensor.t()
  def sharpness(left, right, default) do
    {height, width} = Nx.shape(left)

    rows = %Kernel{
      spirv: image_kernel(:sharpness_rows, left),
      workgroups: {height, 1, 1},
      specialization: %{0 => width, 1 => height}
    }

    pipeline = %Pipeline{
      inputs: [:left, :right],
      stages: [
        {rows, [:left, :right], [partials: Nx.template({height * 6}, :f32)]},
        {column_sums(height, 6), [:partials], [sums: Nx.template({6}, :f32)]}
      ],
      outputs: [:sums]
    }

    Nx.block(pipeline, [left, right], Nx.template({6}, :f32), fn _pipeline, left, right ->
      default.(left, right)
    end)
  end

  @doc """
  `Stage.SpeckleFilter`'s filter of the `f32` `disparity`: a matched
  pixel stays when at least `min_support` of the 48 others in its 7x7
  neighbourhood matched within `max_diff` of it; the others become -1.
  `default` takes the same arguments, the settings as `f32`, and gives
  the same off Vulkan.
  """
  @spec despeckle(Nx.Tensor.t(), Nx.Tensor.t(), Nx.Tensor.t(), function()) :: Nx.Tensor.t()
  def despeckle(disparity, min_support, max_diff, default) do
    {height, width} = shape = Nx.shape(disparity)

    # The shader's workgroups cover 16 x 16 pixels.
    kernel = %Kernel{
      spirv: Map.fetch!(@spirv, :despeckle),
      workgroups: {ceil_div(width, 16), ceil_div(height, 16), 1},
      specialization: %{0 => width, 1 => height}
    }

    pipeline = %Pipeline{
      inputs: [:disparity, :params],
      stages: [{kernel, [:disparity, :params], [output: Nx.template(shape, :f32)]}],
      outputs: [:output]
    }

    Nx.block(
      pipeline,
      [disparity, scalars([min_support, max_diff])],
      Nx.template(shape, :f32),
      fn _pipeline, disparity, params ->
        [min_support, max_diff] = unscalars(params, 2)
        default.(disparity, min_support, max_diff)
      end
    )
  end

  @doc """
  `Stage.RowAlignment`'s sums of the `left` and `right` images, both
  `u8` or both `s32`, and the `f32` `disparity`: per band, the summed
  absolute differences at each row offset of one row in four, then the
  matched count, as its `{4, 6}` `:alignment_sums`. `default` takes the
  same arguments and gives the same off Vulkan.
  """
  @spec row_alignment(Nx.Tensor.t(), Nx.Tensor.t(), Nx.Tensor.t(), function()) :: Nx.Tensor.t()
  def row_alignment(left, right, disparity, default) do
    {height, width} = Nx.shape(left)
    sampled = ceil_div(height, 4)
    values = 4 * 6

    rows = %Kernel{
      spirv: image_kernel(:row_alignment_rows, left),
      workgroups: {sampled, 1, 1},
      specialization: %{0 => width, 1 => height}
    }

    pipeline = %Pipeline{
      inputs: [:left, :right, :disparity],
      stages: [
        {rows, [:left, :right, :disparity], [partials: Nx.template({sampled * values}, :f32)]},
        {column_sums(sampled, values), [:partials], [sums: Nx.template({4, 6}, :f32)]}
      ],
      outputs: [:sums]
    }

    Nx.block(pipeline, [left, right, disparity], Nx.template({4, 6}, :f32), fn _pipeline,
                                                                               left,
                                                                               right,
                                                                               disparity ->
      default.(left, right, disparity)
    end)
  end

  @doc """
  `Stage.TemporalFilter`'s step on the `f32` disparities `current` and
  `previous` and the `f32` count of pairs each pixel has `missed`, with
  `settings` its `[alpha, delta, hold]`: the filtered disparity and the
  new counts, up to 255. `default` takes `current`, `previous`,
  `missed` and the settings, as `f32`, and gives the same off Vulkan.
  """
  @spec temporal_filter(Nx.Tensor.t(), Nx.Tensor.t(), Nx.Tensor.t(), [Nx.Tensor.t()], function()) ::
          {Nx.Tensor.t(), Nx.Tensor.t()}
  def temporal_filter(current, previous, missed, settings, default) do
    shape = Nx.shape(current)
    template = Nx.template(shape, :f32)

    pipeline =
      per_pixel(
        :temporal_filter,
        [:current, :previous, :missed, :params],
        [filtered: template, missed_out: template],
        shape,
        %{0 => Tuple.product(shape)}
      )

    Nx.block(
      pipeline,
      [current, previous, missed, scalars(settings)],
      {template, template},
      fn _pipeline, current, previous, missed, params ->
        default.(current, previous, missed, unscalars(params, 3))
      end
    )
  end

  @doc """
  `Stage.Depth`'s depths of the `f32` `disparity` with the focal length
  `f` in pixels and the baseline `b` in metres: the `u16` millimetres, 0
  beyond 65535 mm, and the `f32` metres, `f × b / d` where `d` is
  positive and 0 elsewhere. `default` takes the same arguments, `f` and
  `b` as `f32`, and gives the same off Vulkan; it also runs on an odd
  number of pixels, as the kernel writes two `u16` per word.
  """
  @spec depth(Nx.Tensor.t(), Nx.Tensor.t(), Nx.Tensor.t(), function()) ::
          {Nx.Tensor.t(), Nx.Tensor.t()}
  def depth(disparity, f, b, default) do
    if rem(Nx.size(disparity), 2) == 0,
      do: depth_kernel(disparity, f, b, default),
      else: default.(disparity, Nx.as_type(f, :f32), Nx.as_type(b, :f32))
  end

  defp depth_kernel(disparity, f, b, default) do
    shape = Nx.shape(disparity)
    pixels = Tuple.product(shape)

    kernel = %Kernel{
      spirv: Map.fetch!(@spirv, :depth),
      workgroups: {ceil_div(ceil_div(pixels, 2), @group), 1, 1},
      specialization: %{0 => pixels}
    }

    outputs = [depth_mm: Nx.template(shape, :u16), depth_m: Nx.template(shape, :f32)]

    pipeline = %Pipeline{
      inputs: [:disparity, :params],
      stages: [{kernel, [:disparity, :params], outputs}],
      outputs: [:depth_mm, :depth_m]
    }

    Nx.block(
      pipeline,
      [disparity, scalars([f, b])],
      {outputs[:depth_mm], outputs[:depth_m]},
      fn _pipeline, disparity, params ->
        [f, b] = unscalars(params, 2)
        default.(disparity, f, b)
      end
    )
  end

  @doc """
  `Stage.PointCloud`'s grid of the `f32` `depth_m`, with `settings` its
  `[focal_length_px, cx, cy]`: the `{height / decimation, width /
  decimation, 3}` `f32` points of every `decimation`-th pixel, NaN outside
  5 cm to 20 m, and their number kept, as an `f32` scalar. `default`
  takes `depth_m` and the settings, as `f32`, and gives the same off
  Vulkan.
  """
  @spec point_cloud(Nx.Tensor.t(), [Nx.Tensor.t()], pos_integer(), function()) ::
          {Nx.Tensor.t(), Nx.Tensor.t()}
  def point_cloud(depth_m, settings, decimation, default) do
    {height, width} = Nx.shape(depth_m)
    {grid_height, grid_width} = {div(height, decimation), div(width, decimation)}
    grid = Nx.template({grid_height, grid_width, 3}, :f32)
    kept = Nx.template({}, :f32)

    rows = %Kernel{
      spirv: Map.fetch!(@spirv, :point_cloud_rows),
      workgroups: {grid_height, 1, 1},
      specialization: %{0 => width, 1 => grid_width, 2 => decimation}
    }

    pipeline = %Pipeline{
      inputs: [:depth_m, :params],
      stages: [
        {rows, [:depth_m, :params], [grid: grid, kept_rows: Nx.template({grid_height}, :f32)]},
        {column_sums(grid_height, 1), [:kept_rows], [kept: kept]}
      ],
      outputs: [:grid, :kept]
    }

    Nx.block(pipeline, [depth_m, scalars(settings)], {grid, kept}, fn _pipeline,
                                                                      depth_m,
                                                                      params ->
      default.(depth_m, unscalars(params, 3))
    end)
  end

  @doc """
  `Stage.Quality`'s five sums of the `f32` disparities `current` and
  `previous`: the matched pixels, their disparity and its square, the
  pixels matched in both, and their absolute change. `default` takes the
  same arguments and gives the same off Vulkan.
  """
  @spec quality(Nx.Tensor.t(), Nx.Tensor.t(), function()) :: Nx.Tensor.t()
  def quality(current, previous, default) do
    {height, width} = Nx.shape(current)

    rows = %Kernel{
      spirv: Map.fetch!(@spirv, :quality_rows),
      workgroups: {height, 1, 1},
      specialization: %{0 => width}
    }

    pipeline = %Pipeline{
      inputs: [:current, :previous],
      stages: [
        {rows, [:current, :previous], [partials: Nx.template({height * 5}, :f32)]},
        {column_sums(height, 5), [:partials], [sums: Nx.template({5}, :f32)]}
      ],
      outputs: [:sums]
    }

    Nx.block(pipeline, [current, previous], Nx.template({5}, :f32), fn _pipeline,
                                                                       current,
                                                                       previous ->
      default.(current, previous)
    end)
  end

  # One kernel run once per pixel of `shape`, reading `inputs` and writing `outputs`.
  defp per_pixel(name, inputs, outputs, shape, specialization) do
    kernel = %Kernel{
      spirv: Map.fetch!(@spirv, name),
      workgroups: {ceil_div(Tuple.product(shape), @group), 1, 1},
      specialization: specialization
    }

    %Pipeline{inputs: inputs, stages: [{kernel, inputs, outputs}], outputs: Keyword.keys(outputs)}
  end

  # Scalar settings as the f32 vector a kernel reads them from.
  defp scalars(values) do
    values |> Enum.map(&(&1 |> Nx.as_type(:f32) |> Nx.reshape({1}))) |> Nx.concatenate()
  end

  # The settings `scalars/1` packed, for a default function, which sees only the block's inputs.
  defp unscalars(vector, count), do: for(i <- 0..(count - 1), do: vector[i])

  defp column_sums(rows, columns) do
    %Kernel{
      spirv: Map.fetch!(@spirv, :column_sums),
      workgroups: {columns, 1, 1},
      specialization: %{0 => rows, 1 => columns}
    }
  end

  # The variant of an image-reading kernel for `image`'s type: s32 pixels, or bytes read as words.
  defp image_kernel(name, image) do
    variant = if Nx.type(image) == {:s, 32}, do: "words", else: "bytes"
    Map.fetch!(@spirv, :"#{name}_#{variant}")
  end

  defp ceil_div(a, b), do: div(a + b - 1, b)
end
