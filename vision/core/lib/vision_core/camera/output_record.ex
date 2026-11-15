defmodule VisionCore.Camera.OutputRecord do
  @moduledoc """
  The records a capture program writes for a camera's named outputs
  (`VisionCore.Camera.Output`), one per sent output of a frame, which
  `VisionCore.Camera.V4L2Single` and `VisionCore.Camera.LibCamera` read
  beside their own records:

      uint8   tag                 # 7 = OUTPUT_FRAME
      uint8   output              # the output's index
      uint16  width   LE
      uint16  height  LE
      int64   capture_ns LE       # frame start, kernel CLOCK_MONOTONIC
      bytes   rgb                 # width * height * 3, R, G, B

  or the same header under tag 8, OUTPUT_JPEG, then the JPEG of the
  `width` x `height` image, or under tag 9, OUTPUT_H264, then a byte of
  flags, bit 0 set on a key frame, then the frame's NAL units in Annex B
  form.
  """

  alias VisionCore.Camera.Frame
  alias VisionCore.Timing

  @output_frame_tag 7
  @output_jpeg_tag 8
  @output_h264_tag 9
  @key_frame_flag 1

  @doc "Whether `tag`, a record's first byte, is an output record's, which `parse/1` reads."
  defguard output_tag?(tag) when tag in [@output_frame_tag, @output_jpeg_tag, @output_h264_tag]

  @doc """
  The output record `record` as `{:frame, index, frame}`, `index` the
  output's and `frame` without its label, or `{:error,
  :malformed_record}` for one whose image is missing or of the wrong
  size.
  """
  def parse(
        <<@output_frame_tag, output, width::little-16, height::little-16,
          kernel_ns::little-signed-64, rgb::binary>>
      )
      when byte_size(rgb) == width * height * 3 do
    {:frame, output,
     %Frame{
       label: nil,
       width: width,
       height: height,
       capture_ns: Timing.monotonic_from_kernel(kernel_ns),
       rgb: rgb
     }}
  end

  def parse(
        <<@output_jpeg_tag, output, width::little-16, height::little-16,
          kernel_ns::little-signed-64, jpeg::binary>>
      )
      when byte_size(jpeg) > 0 do
    {:frame, output,
     %Frame{
       label: nil,
       width: width,
       height: height,
       capture_ns: Timing.monotonic_from_kernel(kernel_ns),
       jpeg: jpeg
     }}
  end

  def parse(
        <<@output_h264_tag, output, width::little-16, height::little-16,
          kernel_ns::little-signed-64, flags, h264::binary>>
      )
      when byte_size(h264) > 0 do
    {:frame, output,
     %Frame{
       label: nil,
       width: width,
       height: height,
       capture_ns: Timing.monotonic_from_kernel(kernel_ns),
       h264: h264,
       keyframe?: Bitwise.band(flags, @key_frame_flag) != 0
     }}
  end

  def parse(_malformed), do: {:error, :malformed_record}
end
