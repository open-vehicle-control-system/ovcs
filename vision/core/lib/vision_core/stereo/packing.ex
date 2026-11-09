defmodule VisionCore.Stereo.Packing do
  @moduledoc """
  8-bit images as 32-bit words, four pixels a word, for a device whose
  buffers cannot hold bytes, such as a Vulkan GPU without 8-bit storage.

  A `{height, width}` `u8` image and its `{height, width / 4}` `u32`
  packing are the same bytes, so packing on the CPU copies nothing. Inside
  a compiled function, `unpack/2` turns the words back into pixels with
  shifts and masks, and `pack_image/1` packs 32-bit pixels back, so no
  8-bit buffer crosses to or from the device.
  """

  @shifts [0, 8, 16, 24]

  @doc "The `u32` `{height, width / 4}` view of `width` × `height` bytes, pixel 0 in word 0's low byte."
  @spec pack(binary(), pos_integer(), pos_integer()) :: Nx.Tensor.t()
  def pack(bytes, width, height) when rem(width, 4) == 0 do
    bytes |> Nx.from_binary({:u, 32}) |> Nx.reshape({height, div(width, 4)})
  end

  @doc "In a compiled function: the `{height, width}` image of `type` that `packed` holds."
  @spec unpack(Nx.Tensor.t(), Nx.Type.t()) :: Nx.Tensor.t()
  def unpack(packed, type) do
    {height, words} = Nx.shape(packed)

    @shifts
    |> Enum.map(&(packed |> Nx.right_shift(&1) |> Nx.bitwise_and(255)))
    |> Nx.stack(axis: -1)
    |> Nx.reshape({height, words * 4})
    |> Nx.as_type(type)
  end

  @doc "In a compiled function: the `u32` words of the `{height, width}` `image` of pixel values."
  @spec pack_image(Nx.Tensor.t()) :: Nx.Tensor.t()
  def pack_image(image) do
    {height, width} = Nx.shape(image)
    bytes = image |> Nx.as_type({:u, 32}) |> Nx.reshape({height, div(width, 4), 4})

    @shifts
    |> Enum.with_index()
    |> Enum.map(fn {shift, index} -> bytes[[.., .., index]] |> Nx.left_shift(shift) end)
    |> Enum.reduce(&Nx.bitwise_or/2)
  end

  @doc "On the CPU: the `u8` image a downloaded `u32` packing holds."
  @spec unpack_download(Nx.Tensor.t()) :: Nx.Tensor.t()
  def unpack_download(packed) do
    {height, words} = Nx.shape(packed)
    packed |> Nx.to_binary() |> Nx.from_binary({:u, 8}) |> Nx.reshape({height, words * 4})
  end
end
