defmodule VisionApiWeb.StatusPresenter do
  @moduledoc """
  A `VisionCore.Status` snapshot as the `"status"` event's payload: the
  same fields with camelCase keys, states as strings, and
  `:stereo_segment_percent` as `stereoLoadPercent`. A camera's or the
  sync's fields that were not measured are left out.
  """

  @camera_keys %{
    present: :present,
    fps: :fps,
    exposure_time_us: :exposureTimeUs,
    analogue_gain: :analogueGain,
    lens_position: :lensPosition,
    colour_temperature: :colourTemperature
  }
  @sync_keys %{
    present: :present,
    pairs: :pairs,
    offset_max_ms: :offsetMaxMs,
    offset_median_ms: :offsetMedianMs
  }

  @spec present(VisionCore.Status.snapshot()) :: map()
  def present(snapshot) do
    %{
      cameras: %{
        left: rename(snapshot.cameras.left, @camera_keys),
        right: rename(snapshot.cameras.right, @camera_keys)
      },
      sync: rename(snapshot.sync, @sync_keys),
      hailo: Atom.to_string(snapshot.hailo),
      depthHz: snapshot.depth_hz,
      cpuPercent: snapshot.cpu_percent,
      stereoLoadPercent: snapshot.stereo_segment_percent,
      alignment: alignment(snapshot.alignment),
      sharpness: snapshot.sharpness,
      quality: quality(snapshot.quality),
      zenoh: Atom.to_string(snapshot.zenoh)
    }
  end

  defp rename(fields, keys) do
    for {key, value} <- fields, Map.has_key?(keys, key), into: %{}, do: {keys[key], value}
  end

  defp alignment(nil), do: nil

  defp alignment(alignment),
    do: %{offsetRows: alignment.offset_rows, bandOffsetRows: alignment.band_offset_rows}

  defp quality(nil), do: nil

  defp quality(quality) do
    %{
      matchedPercent: quality.matched_percent,
      meanDisparityPx: quality.mean_disparity_px,
      spreadPx: quality.spread_px,
      jitterPx: quality.jitter_px
    }
  end
end
