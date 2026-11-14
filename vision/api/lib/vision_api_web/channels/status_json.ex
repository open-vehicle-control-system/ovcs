defmodule VisionApiWeb.StatusJSON do
  @moduledoc """
  A `VisionCore.Status` snapshot as the `"status"` event's payload: the
  same fields with camelCase keys (`cameras` holds the sides and each camera
  of its own, by name), states as strings, and
  `:stereo_segment_percent` as `stereoLoadPercent`. The NPU is `nil`
  without one. `pipelines` holds each pipeline's times by its name
  (`VisionCore.StageTimes`): `totalMs`, each of its `stages`' time by
  the stage's name, and its `segments`, each with its `stages`' names
  and its `ms`. `distances` holds, by its name, each pipeline on a
  camera of its own: its `camera`, whether the stereo depth gives its
  results distances (`available`) and, when it does not, the `reason`
  as a string (`VisionCore.CameraDepth.unprojectable_reason/1`). A
  camera's or the sync's fields that were not measured
  are left out. Each exporter's status is a `level`, `ok`, `warning` or
  `off`, and a `detail`; the API's own comes last, as
  `GET /api/exporters` lists it. The CPU's load is the board's
  (`VisionApiWeb.BoardJSON`). `pair` holds the
  `VisionCore.Stereo.PairCheck` checks, `timing`,
  `rows`, `focus` and `brightness`, and `depth` the
  `VisionCore.Stereo.DepthCheck` checks, `rate` and `range`, with
  camelCase keys; their levels, cameras, directions and issues are
  strings, as each camera's `issues`.
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
      cameras:
        Map.new(snapshot.cameras, fn {name, camera} -> {name, rename(camera, @camera_keys)} end),
      sync: rename(snapshot.sync, @sync_keys),
      pair: checks(snapshot.pair),
      depth: checks(snapshot.depth),
      npu: npu(snapshot.npu),
      pipelines: Map.new(snapshot.pipelines, fn {name, times} -> {name, times(times)} end),
      distances: Map.new(snapshot.distances, fn {name, why} -> {name, distances(why)} end),
      calibrated: snapshot.calibrated,
      depthHz: snapshot.depth_hz,
      stereoLoadPercent: snapshot.stereo_segment_percent,
      alignment: alignment(snapshot.alignment),
      sharpness: snapshot.sharpness,
      quality: quality(snapshot.quality),
      exporters: Enum.map(snapshot.exporters, &exporter/1) ++ [api()]
    }
  end

  # The API pushes this status, so it is answering.
  defp api, do: Map.put(ExporterJSON.api(), :status, %{level: "ok", detail: "Answering"})

  defp exporter(exporter),
    do: %{id: exporter.id, name: exporter.name, status: ExporterJSON.status(exporter.status)}

  defp rename(fields, keys) do
    for {key, value} <- fields, Map.has_key?(keys, key), into: %{}, do: {keys[key], value}
  end

  defp checks(checks), do: Map.new(checks, fn {name, check} -> {name, camelize(check)} end)

  # A check's keys are its checker's own, a fixed set.
  defp camelize(check) do
    Map.new(check, fn {key, value} ->
      [first | rest] = key |> Atom.to_string() |> String.split("_")
      {String.to_atom(Enum.join([first | Enum.map(rest, &String.capitalize/1)])), value}
    end)
  end

  defp npu(nil), do: nil

  defp npu(npu) do
    %{
      kind: npu.kind,
      state: Atom.to_string(npu.state),
      loadPercent: npu.load_percent,
      pipelines:
        Map.new(npu.pipelines, fn {name, %{inference_ms: ms}} -> {name, %{inferenceMs: ms}} end)
    }
  end

  defp times(times),
    do: %{totalMs: times.total_ms, stages: times.stages, segments: times.segments}

  defp distances(%{camera: camera, reason: nil}),
    do: %{camera: camera, available: true, reason: nil}

  defp distances(%{camera: camera, reason: reason}),
    do: %{camera: camera, available: false, reason: Atom.to_string(reason)}

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
