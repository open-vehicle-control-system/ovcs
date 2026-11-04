defmodule VisionCore.Debug.Export do
  @moduledoc """
  The zip a tuner downloads from the debug exporter: a burst of stereo
  pairs, the unit's state when they were recorded and the last pair's
  images, as plain files under one directory,
  `vision-export-<hostname>-<YYYYMMDDTHHMMSSZ>/`. `build/1` is a pure
  function of the recording it is given; the zip is built in memory.

  The `README.md` the zip carries describes each file. JSON field names are
  camelCase, like the API's; the names of stages and parameters stay as the
  unit gives them.

  ## The recording

    * `:hostname`, `:time` (a `DateTime`) and `:firmware` (a
      `OvcsVehicle.FirmwareInfo`).
    * `:parameters` — `VisionCore.Parameters.groups/0`, or a flat list of
      parameters; each is written as `id`, `value`, `saved` and `state`.
    * `:configuration` — `VisionCore.settings/0`, written as it is.
    * `:calibration` — `%{left: yaml, right: yaml}`, the files in use.
    * `:pairs` — one map per burst pair, in the order the pipeline published
      them, not always consecutive: `:capture_ns`, `:interval_ms` (since the
      burst's previous pair, `nil` when unknown), `:device_ms`, `:sharpness`
      and `:alignment` (as on `VisionCore.Stereo.Pair`), `:metrics`,
      `:stage_ms`, and `:frames`, the `{left, right}` `VisionCore.Camera.Frame`s
      as the cameras delivered them, `nil` for the pairs after the ones kept.
    * `:last_pair` — the last `VisionCore.Stereo.Pair`, with its rectified
      images, disparity and depth.
    * `:snapshots` — the `VisionCore.Status` snapshots of the burst.
    * `:detections` — what the detector published during the burst, `nil`
      for a unit without detection; written as given.
    * `:change_age_ms` — how long before the burst the last change was, `nil`
      when none was recorded; `:changes_during_burst` — 1 when something
      changed during it, 0 otherwise; `:status_available` — whether
      `VisionCore.Status` ran.
    * `:depth_coloured_jpeg` (optional) — the depth as the dashboard colours
      it, `VisionCore.Preview.encode_depth/3`; left out of the zip without it.
  """

  alias VisionCore.Camera.Frame
  alias VisionCore.Debug.Png
  alias VisionCore.Parameters.Group
  alias VisionCore.Stereo.Pair

  # Jet: dark blue for the lowest disparity, through green, to dark red for the highest.
  @palette List.to_tuple(
             for index <- 0..255 do
               channel = fn centre ->
                 round(255 * max(0.0, min(1.0, 1.5 - abs(4 * index / 255 - centre))))
               end

               <<channel.(3), channel.(2), channel.(1)>>
             end
           )
  @identity_figures ["index", "captureNs"]

  @doc """
  The export of `recording`, as `{filename, zip}`: the zip's name, and its
  bytes. See the module doc for the recording.
  """
  @spec build(map()) :: {String.t(), binary()}
  def build(recording) do
    directory = directory_name(recording)

    entries =
      for {path, content} <- files(recording),
          do: {String.to_charlist(directory <> "/" <> path), content}

    {:ok, {_name, zip}} = :zip.create(~c"#{directory}.zip", entries, [:memory])
    {directory <> ".zip", zip}
  end

  defp directory_name(recording) do
    hostname = String.replace(recording.hostname, ~r/[^A-Za-z0-9._-]+/, "-")
    "vision-export-#{hostname}-#{Calendar.strftime(utc(recording.time), "%Y%m%dT%H%M%SZ")}"
  end

  defp utc(time), do: time |> DateTime.to_unix() |> DateTime.from_unix!()

  defp files(recording) do
    pair = recording.last_pair
    size = Pair.size(pair)
    colour_range = disparity_colour_range(pair)

    [
      {"README.md", readme(recording)},
      {"manifest.json", json(manifest(recording, size, colour_range))},
      {"parameters.json", json(parameters(recording.parameters))},
      {"configuration.json", json(recording.configuration)},
      {"calibration/left.yaml", recording.calibration.left},
      {"calibration/right.yaml", recording.calibration.right},
      {"figures.json", json(figures(recording))},
      {"timings.json", json(timings(recording.pairs))}
    ] ++
      detection_files(recording.detections) ++
      frame_files(recording.pairs) ++
      last_files(pair, size, colour_range) ++
      depth_coloured_files(Map.get(recording, :depth_coloured_jpeg))
  end

  defp json(term), do: Jason.encode!(term, pretty: true) <> "\n"

  defp detection_files(nil), do: []
  defp detection_files(detections), do: [{"detections.json", json(detections)}]

  defp frame_files(pairs) do
    pairs
    |> Enum.with_index()
    |> Enum.flat_map(fn
      {%{frames: {left, right}}, index} ->
        [frame_file(index, "left", left), frame_file(index, "right", right)]

      {_pair, _index} ->
        []
    end)
  end

  defp frame_file(index, side, %Frame{grey: grey} = frame) when is_binary(grey),
    do: {"frames/#{frame_number(index)}-#{side}.png", Png.grey(grey, frame.width, frame.height)}

  defp frame_file(index, side, %Frame{jpeg: jpeg}) when is_binary(jpeg),
    do: {"frames/#{frame_number(index)}-#{side}.jpg", jpeg}

  defp frame_number(index), do: index |> Integer.to_string() |> String.pad_leading(3, "0")

  defp last_files(pair, {width, height}, colour_range) do
    [
      {"last/left-rectified.png", Png.grey(Nx.to_binary(pair.left), width, height)},
      {"last/right-rectified.png", Png.grey(Nx.to_binary(pair.right), width, height)},
      {"last/disparity.f32", pair.disparity_bytes},
      {"last/disparity.png",
       Png.rgb(coloured_disparity(pair.disparity_bytes, colour_range), width, height)},
      {"last/depth.png", Png.grey16(pair.depth, width, height)}
    ]
  end

  defp depth_coloured_files(nil), do: []
  defp depth_coloured_files(jpeg), do: [{"last/depth-coloured.jpg", jpeg}]

  # The matcher's search range when the pair has it, so exports of one setup colour alike.
  defp disparity_colour_range(%Pair{disparity_range: %{}} = pair),
    do: widen(Pair.disparity_bounds(pair))

  defp disparity_colour_range(%Pair{disparity_bytes: disparity_bytes}) do
    case for(<<disparity::float-32-little <- disparity_bytes>>, disparity > 0, do: disparity) do
      [] -> {0.0, 1.0}
      matched -> widen({Enum.min(matched), Enum.max(matched)})
    end
  end

  defp widen({low, high}) when high > low, do: {low, high}
  defp widen({low, _high}), do: {low, low + 1.0}

  defp coloured_disparity(disparity_bytes, {low, high}) do
    for <<disparity::float-32-little <- disparity_bytes>>, into: <<>> do
      if disparity > 0,
        do: elem(@palette, palette_index((disparity - low) / (high - low))),
        else: <<0, 0, 0>>
    end
  end

  defp palette_index(fraction), do: fraction |> Kernel.*(255) |> round() |> max(0) |> min(255)

  defp manifest(recording, {width, height}, {low, high}) do
    %{
      "time" => recording.time |> utc() |> DateTime.to_iso8601(),
      "hostname" => recording.hostname,
      "firmware" => camel_keys(recording.firmware),
      "burstPairs" => length(recording.pairs),
      "framesKept" => Enum.count(recording.pairs, & &1.frames),
      "statusSnapshots" => length(recording.snapshots),
      "statusAvailable" => recording.status_available,
      "changeAgeMs" => recording.change_age_ms,
      "changesDuringBurst" => recording.changes_during_burst,
      "imageSize" => %{"width" => width, "height" => height},
      "formats" => %{
        "frames" => %{
          "grey" => "8-bit grey PNG, as the camera delivered it (.png)",
          "jpeg" => "the camera's JPEG bytes, unchanged (.jpg)"
        },
        "last/left-rectified.png" => %{"type" => "8-bit grey PNG"},
        "last/right-rectified.png" => %{"type" => "8-bit grey PNG"},
        "last/disparity.f32" => %{
          "type" => "float32",
          "byteOrder" => "little-endian",
          "layout" => "row-major",
          "width" => width,
          "height" => height,
          "unit" => "pixel",
          "unmatched" => "a pixel is matched when its value is above 0"
        },
        "last/disparity.png" => %{
          "type" => "8-bit RGB PNG",
          "colourRangePx" => [low, high],
          "unmatched" => "black"
        },
        "last/depth.png" => %{
          "type" => "16-bit grey PNG",
          "unit" => "millimetre",
          "noDepth" => 0
        },
        "last/depth-coloured.jpg" => %{"type" => "JPEG"}
      }
    }
  end

  defp camel_keys(nil), do: %{}
  defp camel_keys(%_{} = struct), do: struct |> Map.from_struct() |> camel_keys()
  defp camel_keys(map), do: Map.new(map, fn {key, value} -> {camel(key), value} end)

  defp camel(name) do
    [first | rest] = name |> to_string() |> String.split("_")
    first <> Enum.map_join(rest, &String.capitalize/1)
  end

  defp parameters(parameters) do
    parameters
    |> Enum.flat_map(fn
      %Group{parameters: members} -> members
      parameter -> [parameter]
    end)
    |> Enum.map(fn parameter ->
      %{
        "id" => parameter.id,
        "value" => parameter.value,
        "saved" => parameter.saved,
        "state" => to_string(parameter.state)
      }
    end)
  end

  defp figures(recording) do
    pairs = recording.pairs |> Enum.with_index() |> Enum.map(&pair_figures/1)
    snapshots = recording.snapshots |> Enum.with_index() |> Enum.map(&snapshot_figures/1)

    %{
      "pairs" => pairs,
      "snapshots" => snapshots,
      "summary" => Map.merge(summarise(pairs), summarise(snapshots))
    }
  end

  defp pair_figures({pair, index}) do
    metrics = for {name, value, _unit} <- pair.metrics, into: %{}, do: {camel(name), value}

    Map.merge(metrics, %{
      "index" => index,
      "captureNs" => pair.capture_ns,
      "intervalMs" => pair.interval_ms,
      "deviceMs" => pair.device_ms,
      "sharpnessLeft" => pair.sharpness[:left],
      "sharpnessRight" => pair.sharpness[:right],
      "alignmentOffsetRows" => pair.alignment[:offset_rows],
      "alignmentBandOffsetRows" => pair.alignment[:band_offset_rows]
    })
  end

  defp snapshot_figures({snapshot, index}) do
    %{
      "index" => index,
      "depthHz" => snapshot[:depth_hz],
      "cpuPercent" => snapshot[:cpu_percent],
      "stereoLoadPercent" => snapshot[:stereo_segment_percent]
    }
    |> Map.merge(scalars("left_camera", snapshot[:cameras][:left]))
    |> Map.merge(scalars("right_camera", snapshot[:cameras][:right]))
    |> Map.merge(scalars("sync", snapshot[:sync]))
  end

  defp scalars(prefix, fields) do
    for {name, value} <- fields || %{},
        is_number(value) or is_boolean(value),
        into: %{},
        do: {camel("#{prefix}_#{name}"), value}
  end

  defp summarise(entries) do
    entries
    |> Enum.flat_map(&Map.to_list/1)
    |> Enum.filter(fn {name, value} -> is_number(value) and name not in @identity_figures end)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Map.new(fn {name, samples} -> {name, statistics(samples)} end)
  end

  defp statistics(samples) do
    count = length(samples)
    mean = Enum.sum(samples) / count
    variance = Enum.sum(for sample <- samples, do: (sample - mean) * (sample - mean)) / count

    %{
      "mean" => mean,
      "min" => Enum.min(samples),
      "max" => Enum.max(samples),
      "std" => :math.sqrt(variance),
      "n" => count
    }
  end

  defp timings(pairs) do
    pairs
    |> Enum.flat_map(fn pair ->
      for {stage, duration_ms} <- pair.stage_ms, do: {stage_name(stage), duration_ms}
    end)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Map.new(fn {stage, samples} ->
      sorted = Enum.sort(samples)

      {stage,
       %{
         "median" => percentile(sorted, 0.5),
         "p95" => percentile(sorted, 0.95),
         "max" => percentile(sorted, 1.0),
         "n" => length(sorted)
       }}
    end)
  end

  defp stage_name(stage) when is_atom(stage) or is_binary(stage), do: to_string(stage)
  defp stage_name(stage), do: inspect(stage)

  # Nearest rank, as the pipeline's log line reads its percentiles.
  defp percentile(sorted, quantile) do
    count = length(sorted)
    index = max(min(round(quantile * count) - 1, count - 1), 0)
    Float.round(Enum.at(sorted, index) / 1, 3)
  end

  defp readme(recording) do
    firmware = camel_keys(recording.firmware)
    kept = Enum.count(recording.pairs, & &1.frames)

    """
    # Vision unit export

    Taken from `#{recording.hostname}` at #{recording.time |> utc() |> DateTime.to_iso8601()}, \
    firmware revision #{firmware["revision"] || "unknown"}.

    ## How it was taken

    - The burst holds #{length(recording.pairs)} pairs, in the order the stereo pipeline \
    published them. A pair the pipeline dropped while busy, or one the exporter skipped while \
    it was behind, is not among them: `intervalMs` is longer there. The raw frames of the \
    first #{kept} are kept.
    - #{change_age(recording.change_age_ms)}
    - Something changed during the burst: #{yes_no(recording.changes_during_burst)}.
    - #{snapshot_count(recording)}

    ## Files

    | File | Content |
    |---|---|
    | `manifest.json` | Time, hostname, firmware, burst size, change age, changes during the burst, image size and the format of each binary file |
    | `parameters.json` | Every parameter: `id`, `value`, `saved` (the saved value) and `state` |
    | `configuration.json` | The unit's configuration |
    | `calibration/left.yaml`, `calibration/right.yaml` | The calibration files in use, as they are |
    | `figures.json` | `pairs`: each burst pair's figures. `snapshots`: each status snapshot's figures. `summary`: each figure's `mean`, `min`, `max`, `std` and `n` |
    | `timings.json` | Each stage's `median`, `p95` and `max` time in milliseconds over the burst, and `n` |
    | `detections.json` | What the detector published during the burst; present only when the unit has detection |
    | `frames/NNN-left.*`, `frames/NNN-right.*` | The raw frames of the first #{kept} pairs, as the cameras delivered them: grey frames as 8-bit PNG (`.png`), JPEG frames as the JPEG bytes (`.jpg`) |
    | `last/left-rectified.png`, `last/right-rectified.png` | The last pair's rectified images, 8-bit PNG |
    | `last/disparity.f32` | The last pair's disparity: little-endian float32 in pixels, row-major; a pixel is matched when its value is above 0 |
    | `last/disparity.png` | The same disparity coloured for viewing, unmatched pixels black; `manifest.json` gives the range of the colours |
    | `last/depth.png` | The last pair's depth, 16-bit PNG in millimetres, 0 where there is none |
    | `last/depth-coloured.jpg` | The depth as the dashboard colours it; present when it could be encoded |

    ## Reading the figures

    - JSON field names are camelCase. A name ending in `Ms`, `Px`, `Hz`, `Percent` or \
    `Rows` says its unit. Stage names and parameter ids are the unit's own.
    - `std` is the population standard deviation. `n` counts the samples a figure was \
    measured on; a figure that was not measured on a pair is `null` for it and not counted.
    - Besides `captureNs`, `intervalMs`, `deviceMs`, the sharpness and the alignment, a \
    pair's figures are the metrics its stages report, under each stage's name for them: \
    `matchedPercent`, `meanDisparityPx`, `spreadPx` and `jitterPx` from Quality, and \
    `alignRows` from RowAlignment, the same offset as `alignmentOffsetRows`. Each stage's \
    documentation describes its metrics.
    - `median` and `p95` are nearest-rank percentiles, as in the `[pipeline]` log line.
    - The figures of the status snapshots (`depthHz`, `stereoLoadPercent`, `cpuPercent`, \
    the cameras' and the sync's) have one sample a second: their `n` is small, so read \
    their differences as indications.
    """
  end

  defp change_age(nil), do: "No change to the unit's parameters or pipeline has been recorded."

  defp change_age(age_ms),
    do:
      "The last change to the unit's parameters or pipeline was #{round(age_ms)} ms before the burst."

  defp yes_no(0), do: "no"
  defp yes_no(_changes), do: "yes"

  defp snapshot_count(%{status_available: true, snapshots: snapshots}),
    do: "The burst holds #{length(snapshots)} status snapshots, one a second."

  defp snapshot_count(_recording),
    do: "The status was not available: there are no status snapshots."
end
