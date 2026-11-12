defmodule VisionCore.Detection.Backend.Wire do
  @moduledoc """
  The packets `hailo_detect` and `qnn_detect` speak, which
  `VisionCore.Detection.Backend.Hailo` and
  `VisionCore.Detection.Backend.Qnn` hand to
  `VisionCore.Inference.PortBackend`: an image goes down as its
  sequence, its size, its channels and its pixels, and comes back as the
  boxes found on it, in its pixels, which the accelerator's time for the
  inference may follow.
  """

  # Port protocol tags; must match `hailo_detect` and `qnn_detect`.
  @detect_request_tag 1
  @detections_reply_tag 1

  @doc """
  The request for the inference `sequence` on `image`, a `u8`
  `{height, width}` grey or `{height, width, 3}` RGB tensor.
  """
  @spec request(non_neg_integer(), Nx.Tensor.t()) :: iodata()
  def request(sequence, image) do
    {height, width, channels} = image_shape(image)

    [
      <<@detect_request_tag, sequence::little-32, width::little-16, height::little-16, channels>>,
      Nx.to_binary(image)
    ]
  end

  # A grey image is a 2-tuple shape.
  defp image_shape(image) do
    case Nx.shape(image) do
      {height, width} -> {height, width, 1}
      {height, width, channels} -> {height, width, channels}
    end
  end

  @doc """
  The detections a reply carries, with its sequence and its inference
  time in microseconds, `nil` when it carries none; `:error` for a
  packet that is no detections reply.
  """
  @spec parse(binary()) ::
          {:ok, non_neg_integer(), [VisionCore.Detection.Backend.detection()],
           non_neg_integer() | nil}
          | :error
  def parse(<<@detections_reply_tag, sequence::little-32, count::little-16, rest::binary>>),
    do: parse_body(sequence, take_detections(rest, count, []))

  def parse(_packet), do: :error

  # The detections may be followed by the inference time, a `u32` in microseconds.
  defp parse_body(sequence, {detections, <<time_us::little-32, _rest::binary>>}),
    do: {:ok, sequence, detections, time_us}

  defp parse_body(sequence, {detections, _no_time}), do: {:ok, sequence, detections, nil}

  defp take_detections(rest, 0, detections), do: {Enum.reverse(detections), rest}

  defp take_detections(
         <<class_id::little-16, score::little-float-32, x0::little-float-32, y0::little-float-32,
           x1::little-float-32, y1::little-float-32, rest::binary>>,
         count,
         detections
       ) do
    detection = %{class_id: class_id, score: score, x0: x0, y0: y0, x1: x1, y1: y1}
    take_detections(rest, count - 1, [detection | detections])
  end

  defp take_detections(_malformed, _count, detections), do: {Enum.reverse(detections), <<>>}
end
