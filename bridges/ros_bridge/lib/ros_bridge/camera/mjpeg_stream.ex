defmodule RosBridge.Camera.MjpegStream do
  @moduledoc """
  Splits a concatenated MJPEG byte stream into discrete JPEG frames
  by scanning for `SOI` (`FF D8`) and `EOI` (`FF D9`) markers.

  Used by host-side camera drivers (`Camera.Ffmpeg`, `Camera.GStreamer`)
  that receive an MJPEG stream over a Port's stdout. Each one feeds
  partial reads through `split/1` and keeps the returned leftover
  for the next chunk.

  Naive linear scan — fine at the 30 fps host-dev workloads we
  care about. If we ever need much higher throughput, replace with
  a state-machine pass.
  """

  @doc """
  Returns `{complete_frames, leftover}`. Each complete_frame is the
  raw JPEG bytes from `FF D8` through `FF D9` inclusive. `leftover`
  is the trailing partial frame (or empty) — caller must prepend it
  to the next chunk before calling again.
  """
  def split(buffer), do: split(buffer, [])

  defp split(buffer, acc) do
    case find_marker(buffer, 0xD8, 0) do
      nil ->
        {Enum.reverse(acc), buffer}

      soi ->
        case find_marker(buffer, 0xD9, soi + 2) do
          nil ->
            # SOI seen but no terminating EOI yet — drop anything
            # before the SOI (subprocess prologue, partial frame
            # from a prior crash, etc.) and keep from SOI onward
            # for the next chunk.
            <<_::binary-size(soi), tail::binary>> = buffer
            {Enum.reverse(acc), tail}

          eoi ->
            frame_end = eoi + 2

            <<_pre::binary-size(soi), frame::binary-size(frame_end - soi),
              rest::binary>> = buffer

            split(rest, [frame | acc])
        end
    end
  end

  defp find_marker(buffer, marker_byte, from) do
    case buffer do
      <<_::binary-size(from), _::binary>> -> scan(buffer, marker_byte, from)
      _ -> nil
    end
  end

  defp scan(buffer, marker_byte, index) when index + 1 < byte_size(buffer) do
    <<_::binary-size(index), a, b, _::binary>> = buffer

    cond do
      a == 0xFF and b == marker_byte -> index
      true -> scan(buffer, marker_byte, index + 1)
    end
  end

  defp scan(_buffer, _marker_byte, _index), do: nil
end
