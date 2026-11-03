defmodule VisionCore.Camera.MjpegStream do
  @moduledoc """
  Splits a concatenated MJPEG byte stream into discrete JPEG frames
  by scanning for `SOI` (`FF D8`) and `EOI` (`FF D9`) markers.

  Used by `Camera.GStreamer`, which receives an MJPEG stream over a
  Port's stdout: it feeds partial reads through `split/1` and keeps the
  returned leftover for the next chunk.

  A linear scan: host-dev frame rates need nothing faster.
  """

  @doc """
  Returns `{complete_frames, leftover}`. Each complete_frame is the
  raw JPEG bytes from `FF D8` through `FF D9` inclusive. `leftover`
  is the trailing partial frame (or empty) — caller must prepend it
  to the next chunk before calling again.
  """
  def split(buffer), do: split(buffer, [])

  defp split(buffer, frames) do
    case find_marker(buffer, 0xD8, 0) do
      nil ->
        {Enum.reverse(frames), buffer}

      soi_offset ->
        case find_marker(buffer, 0xD9, soi_offset + 2) do
          nil ->
            # Bytes before the SOI are subprocess prologue or a partial frame.
            <<_::binary-size(^soi_offset), tail::binary>> = buffer
            {Enum.reverse(frames), tail}

          eoi_offset ->
            frame_end = eoi_offset + 2

            <<_pre::binary-size(^soi_offset), frame::binary-size(^frame_end - ^soi_offset),
              rest::binary>> = buffer

            split(rest, [frame | frames])
        end
    end
  end

  defp find_marker(buffer, marker_byte, start_offset) do
    case buffer do
      <<_::binary-size(^start_offset), _::binary>> -> scan(buffer, marker_byte, start_offset)
      _ -> nil
    end
  end

  defp scan(buffer, marker_byte, index) when index + 1 < byte_size(buffer) do
    <<_::binary-size(^index), first_byte, second_byte, _::binary>> = buffer

    cond do
      first_byte == 0xFF and second_byte == marker_byte -> index
      true -> scan(buffer, marker_byte, index + 1)
    end
  end

  defp scan(_buffer, _marker_byte, _index), do: nil
end
