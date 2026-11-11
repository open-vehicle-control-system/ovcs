defmodule VisionApiWeb.StatusJSON do
  @moduledoc """
  A `VisionCore.Status` snapshot as the `"status"` event's payload: the
  same fields with camelCase keys, states as strings, and
  `:stereo_segment_percent` as `stereoLoadPercent`. A camera's or the
  sync's fields that were not measured are left out. Each exporter's
  status is a `level` and a `detail`, as in `VisionApiWeb.ExporterJSON`.
  `pair` holds the `VisionCore.Stereo.PairCheck` checks, `timing`, `rows`
  and `focus`, with camelCase keys; their levels, cameras, directions and
  issues are strings, as each camera's `issues`.
  """

  alias VisionApiWeb.ExporterJSON

  @camera_keys %{
    present: :present,
    fps: :fps,
    exposure_time_us: :exposureTimeUs,
    analogue_gain: :analogueGain,
    lens_position: :lensPosition,
    colour_temperature: :colourTemperature,
    issues: :issues
  }
  @sync_keys %{
    present: :present,
    pairs: :pairs,
    offset_max_ms: :offsetMaxMs,
    offset_median_ms: :offsetMedianMs
  }

  @doc "The `\"status\"` event's payload for `snapshot`."
  @spec status(VisionCore.Status.snapshot()) :: map()
  def status(snapshot) do
    %{
      cameras: %{
        left: rename(snapshot.cameras.left, @camera_keys),
        right: rename(snapshot.cameras.right, @camera_keys)
      },
      sync: rename(snapshot.sync, @sync_keys),
      pair: Map.new(snapshot.pair, fn {name, check} -> {name, camelize(check)} end),
      hailo: Atom.to_string(snapshot.hailo),
      depthHz: snapshot.depth_hz,
      cpuPercent: snapshot.cpu_percent,
      stereoLoadPercent: snapshot.stereo_segment_percent,
      alignment: alignment(snapshot.alignment),
      sharpness: snapshot.sharpness,
      quality: quality(snapshot.quality),
      exporters: Enum.map(snapshot.exporters, &exporter/1)
    }
  end

  defp exporter(exporter),
    do: %{id: exporter.id, name: exporter.name, status: ExporterJSON.status(exporter.status)}

  defp rename(fields, keys) do
    for {key, value} <- fields, Map.has_key?(keys, key), into: %{}, do: {keys[key], value}
  end

  # A check's keys are `VisionCore.Stereo.PairCheck`'s own, a fixed set.
  defp camelize(check) do
    Map.new(check, fn {key, value} ->
      [first | rest] = key |> Atom.to_string() |> String.split("_")
      {String.to_atom(Enum.join([first | Enum.map(rest, &String.capitalize/1)])), value}
    end)
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
