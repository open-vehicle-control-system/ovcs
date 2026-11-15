defmodule VisionCore.Segmentation.Backend.Wire do
  @moduledoc """
  The packets `qnn_segment` and `hailo` speak for segmentation, which
  `VisionCore.Segmentation.Backend.Qnn` and `VisionCore.Hailo` hand to
  `VisionCore.Inference.PortBackend`: a band goes down as its sequence,
  its size and its RGB pixels, or to `hailo` as its sequence, its rows
  and the JPEG it is a band of, and comes back as a grid of class ids,
  which the accelerator's time for the inference may follow.
  """

  # Port protocol tag, of a request and of its reply; must match the segmentation Ports'.
  @segment_tag 7
  @segment_jpeg_tag 8

  @doc """
  The request for the inference `sequence` on `band`, a whole RGB image,
  or rows of a JPEG.
  """
  @spec request(non_neg_integer(), VisionCore.Segmentation.Backend.band()) :: iodata()
  def request(sequence, %{jpeg: jpeg, top: top, height: height}),
    do: [<<@segment_jpeg_tag, sequence::little-32, top::little-16, height::little-16>>, jpeg]

  def request(sequence, %{width: width, height: height, rgb: rgb}) do
    [
      <<@segment_tag, sequence::little-32, width::little-16, height::little-16, 3, 0::little-16,
        height::little-16>>,
      rgb
    ]
  end

  @doc """
  The label grid a reply carries, with its sequence and its inference
  time in microseconds, `nil` when it carries none; `nil` labels for an
  empty grid, the Port's answer to a band it could not segment;
  `{:cut_short, sequence}` for a reply holding fewer cells than it says;
  `:error` for a packet that is no labels reply.
  """
  @spec parse(binary()) ::
          {:ok, non_neg_integer(), map() | nil, non_neg_integer() | nil}
          | {:cut_short, non_neg_integer()}
          | :error
  def parse(
        <<@segment_tag, sequence::little-32, width::little-16, height::little-16, rest::binary>>
      ) do
    cells = width * height

    case rest do
      _empty when cells == 0 ->
        {:ok, sequence, nil, nil}

      <<data::binary-size(^cells), time_us::little-32, _rest::binary>> ->
        {:ok, sequence, %{width: width, height: height, data: data}, time_us}

      <<data::binary-size(^cells)>> ->
        {:ok, sequence, %{width: width, height: height, data: data}, nil}

      _short ->
        {:cut_short, sequence}
    end
  end

  def parse(_packet), do: :error
end
