defmodule VisionCore.Debug.ExportTest do
  use ExUnit.Case, async: true

  alias VisionCore.Camera.Frame
  alias VisionCore.Debug.Export
  alias OvcsVehicle.FirmwareInfo
  alias VisionCore.Parameters.{Group, Parameter}
  alias VisionCore.Stereo.Pair
  alias VisionCore.TestPng

  @directory "vision-export-unit-1-20261103T140509Z"
  @width 8
  @height 6
  @depth_mm for index <- 0..47, do: if(rem(index, 5) == 0, do: 0, else: 300 + index * 1_000)
  @spec_files ~w(
    README.md manifest.json parameters.json configuration.json
    calibration/left.yaml calibration/right.yaml figures.json timings.json detections.json
    frames/000-left.png frames/000-right.png frames/001-left.png frames/001-right.png
    last/left-rectified.png last/right-rectified.png last/disparity.f32 last/disparity.png
    last/depth.png last/depth-coloured.jpg
  )

  test "holds the spec's files" do
    {filename, zip} = Export.build(recording())

    assert filename == @directory <> ".zip"
    assert names(zip) == Enum.sort(Enum.map(@spec_files, &Path.join(@directory, &1)))
  end

  test "leaves out the depth JPEG and the detections the recording lacks" do
    {_filename, zip} = Export.build(recording(depth_coloured_jpeg: nil, detections: nil))

    names = names(zip)
    refute Path.join(@directory, "last/depth-coloured.jpg") in names
    refute Path.join(@directory, "detections.json") in names
    assert Path.join(@directory, "last/depth.png") in names
  end

  test "names the zip after the hostname, cleaned of what a path cannot hold, and the UTC time" do
    {filename, zip} = Export.build(recording(hostname: "vision unit/1"))

    assert filename == "vision-export-vision-unit-1-20261103T140509Z.zip"
    assert Enum.all?(names(zip), &String.starts_with?(&1, "vision-export-vision-unit-1-"))
  end

  test "keeps JPEG frames as delivered" do
    jpeg = <<0xFF, 0xD8, 1, 2, 3, 0xFF, 0xD9>>
    {left, right} = frames(0)

    pairs =
      List.update_at(
        recording().pairs,
        0,
        &%{&1 | frames: {%{left | jpeg: jpeg, grey: nil}, right}}
      )

    files = files(recording(pairs: pairs))

    assert files["frames/000-left.jpg"] == jpeg
    refute Map.has_key?(files, "frames/000-left.png")
    assert %{width: @width, height: @height} = TestPng.decode!(files["frames/000-right.png"])
  end

  test "writes grey frames as 8-bit PNG, and none for pairs past the kept ones" do
    files = files(recording())

    image = TestPng.decode!(files["frames/001-left.png"])
    assert %{bit_depth: 8, colour_type: 0} = image
    assert image.pixels == elem(frames(1), 0).grey
    refute Map.has_key?(files, "frames/002-left.png")
  end

  test "summarises each figure with its spread" do
    figures = json(files(recording()), "figures.json")

    assert %{"mean" => 92.0, "min" => 90.0, "max" => 94.0, "std" => std, "n" => 3} =
             figures["summary"]["matchedPercent"]

    assert_in_delta std, :math.sqrt(8 / 3), 1.0e-9
    assert [%{"index" => 0, "matchedPercent" => 90.0}, _second, _third] = figures["pairs"]
  end

  test "counts only the pairs a figure was measured on" do
    figures = json(files(recording()), "figures.json")

    assert %{"mean" => 33.0, "n" => 2} = figures["summary"]["intervalMs"]
    assert %{"mean" => 101.0, "n" => 3} = figures["summary"]["sharpnessLeft"]
    assert %{"n" => 3} = figures["summary"]["alignmentOffsetRows"]
    refute Map.has_key?(figures["summary"], "alignmentBandOffsetRows")
    refute Map.has_key?(figures["summary"], "captureNs")
  end

  test "summarises the status snapshots, skipping a figure that was not measured" do
    figures = json(files(recording()), "figures.json")

    assert length(figures["snapshots"]) == 2
    assert %{"mean" => 30.0, "std" => 1.0, "n" => 2} = figures["summary"]["depthHz"]
    assert %{"mean" => 40.0, "n" => 1} = figures["summary"]["cpuPercent"]
    assert %{"mean" => 55.0, "n" => 2} = figures["summary"]["stereoLoadPercent"]
    assert %{"mean" => 29.0, "n" => 2} = figures["summary"]["rightCameraFps"]
    assert %{"max" => 2.0} = figures["summary"]["syncOffsetMaxMs"]
  end

  test "times each stage over the burst, as the pipeline log line does" do
    timings = json(files(recording()), "timings.json")

    assert timings["total"] == %{"median" => 31.0, "p95" => 32.0, "max" => 32.0, "n" => 3}
    assert timings["rectification"] == %{"median" => 5.0, "p95" => 5.0, "max" => 5.0, "n" => 3}
  end

  test "writes the raw disparity as float32 and the depth as 16-bit PNG" do
    recording = recording()
    files = files(recording)

    assert byte_size(files["last/disparity.f32"]) == 8 * 6 * 4
    assert files["last/disparity.f32"] == recording.last_pair.disparity_bytes

    depth = TestPng.decode!(files["last/depth.png"])
    assert %{width: @width, height: @height, bit_depth: 16, colour_type: 0} = depth
    assert for(<<mm::16-big <- depth.pixels>>, do: mm) == @depth_mm
  end

  test "writes the rectified images as 8-bit PNG" do
    recording = recording()
    files = files(recording)

    left = TestPng.decode!(files["last/left-rectified.png"])
    assert %{width: @width, height: @height, bit_depth: 8, colour_type: 0} = left
    assert left.pixels == Nx.to_binary(recording.last_pair.left)

    assert TestPng.decode!(files["last/right-rectified.png"]).pixels ==
             Nx.to_binary(recording.last_pair.right)
  end

  test "colours the disparity over the matcher's range and leaves unmatched pixels black" do
    disparity = [1.0, 10.0, -1.0 | List.duplicate(5.0, 45)]
    range = %{min_disparity: 1, num_disparities: 10, block_size: 5}
    files = files(recording(last_pair: last_pair(disparity, range)))

    image = TestPng.decode!(files["last/disparity.png"])
    assert %{width: @width, height: @height, bit_depth: 8, colour_type: 2} = image
    assert <<0, 0, 128, 128, 0, 0, 0, 0, 0, _rest::binary>> = image.pixels

    assert json(files, "manifest.json")["formats"]["last/disparity.png"]["colourRangePx"] == [
             1.0,
             10.0
           ]
  end

  test "colours the disparity over the matched values when the pair has no range" do
    files = files(recording())

    image = TestPng.decode!(files["last/disparity.png"])
    assert <<0, 0, 0, _rest::binary>> = image.pixels

    assert [low, high] =
             json(files, "manifest.json")["formats"]["last/disparity.png"]["colourRangePx"]

    assert low < high
  end

  test "lists every parameter with its value, saved value and state" do
    parameters = json(files(recording()), "parameters.json")

    assert [
             %{"id" => "stereo.block_size", "value" => 5, "saved" => 7, "state" => "unsaved"},
             %{"id" => "camera.gain", "value" => 1.5, "saved" => nil, "state" => "builtin"}
           ] = parameters

    flat = Enum.flat_map(recording().parameters, & &1.parameters)
    assert json(files(recording(parameters: flat)), "parameters.json") == parameters
  end

  test "keeps the configuration and the calibration files as they are" do
    files = files(recording())

    assert json(files, "configuration.json") == %{"components" => [], "exporters" => []}
    assert files["calibration/left.yaml"] == "left calibration\n"
    assert files["calibration/right.yaml"] == "right calibration\n"
  end

  test "leaves detections.json out without detection" do
    files = files(recording(detections: nil))

    refute Map.has_key?(files, "detections.json")
    assert [%{"label" => "cup"}] = json(files(recording()), "detections.json")
  end

  test "records the change age and the changes during the burst in the manifest" do
    files = files(recording(change_age_ms: 2_150, changes_during_burst: 1))

    manifest = json(files, "manifest.json")
    assert manifest["changeAgeMs"] == 2_150
    assert manifest["changesDuringBurst"] == 1
    assert manifest["statusAvailable"] == true
    assert files["README.md"] =~ "2150 ms"
    assert files["README.md"] =~ "3 pairs"
    assert files["README.md"] =~ "Something changed during the burst: yes."
    assert files(recording())["README.md"] =~ "Something changed during the burst: no."
  end

  test "says in the README that pairs can be skipped, and how to read the stages' metrics" do
    readme = files(recording())["README.md"]

    refute readme =~ "consecutive"
    assert readme =~ "skipped"
    assert readme =~ "`intervalMs`"
    assert readme =~ "`alignRows`"
  end

  test "describes the burst, the unit and the binary files in the manifest" do
    manifest = json(files(recording(status_available: false, snapshots: [])), "manifest.json")

    assert manifest["time"] == "2026-11-03T14:05:09Z"
    assert manifest["hostname"] == "unit-1"
    assert manifest["firmware"]["nervesSystemVersion"] == "1.0.0"
    assert manifest["burstPairs"] == 3
    assert manifest["framesKept"] == 2
    assert manifest["statusSnapshots"] == 0
    assert manifest["statusAvailable"] == false
    assert manifest["imageSize"] == %{"width" => @width, "height" => @height}

    assert %{"type" => "float32", "byteOrder" => "little-endian"} =
             manifest["formats"]["last/disparity.f32"]

    assert %{"unit" => "millimetre", "noDepth" => 0} = manifest["formats"]["last/depth.png"]
  end

  test "records no change age for a unit that has not changed" do
    files = files(recording(change_age_ms: nil))

    assert json(files, "manifest.json")["changeAgeMs"] == nil
    assert files["README.md"] =~ "No change"
  end

  defp names(zip) do
    {:ok, entries} = :zip.unzip(zip, [:memory])
    entries |> Enum.map(fn {name, _content} -> List.to_string(name) end) |> Enum.sort()
  end

  defp files(recording) do
    {_filename, zip} = Export.build(recording)
    {:ok, entries} = :zip.unzip(zip, [:memory])
    prefix = @directory <> "/"

    Map.new(entries, fn {name, content} ->
      {String.replace_prefix(List.to_string(name), prefix, ""), content}
    end)
  end

  defp json(files, name) when is_map(files), do: Jason.decode!(Map.fetch!(files, name))

  defp recording(overrides \\ []) do
    %{
      hostname: "unit-1",
      time: ~U[2026-11-03 14:05:09Z],
      firmware: %FirmwareInfo{
        revision: "abc123",
        target: "rpi5",
        nerves_system: "vision_rpi5",
        nerves_system_version: "1.0.0",
        vehicle: "OVCS Mini"
      },
      parameters: [
        %Group{
          id: "stereo",
          parameters: [%Parameter{id: "stereo.block_size", value: 5, saved: 7, state: :unsaved}]
        },
        %Group{
          id: "camera",
          parameters: [%Parameter{id: "camera.gain", value: 1.5, saved: nil, state: :builtin}]
        }
      ],
      configuration: %{"components" => [], "exporters" => []},
      calibration: %{left: "left calibration\n", right: "right calibration\n"},
      pairs: Enum.map(0..2, &burst_pair/1),
      last_pair: last_pair(),
      snapshots: [snapshot(29.0, nil, 1.0), snapshot(31.0, 40.0, 2.0)],
      detections: [%{"label" => "cup", "score" => 0.9}],
      change_age_ms: 2_150,
      changes_during_burst: 0,
      status_available: true,
      depth_coloured_jpeg: <<0xFF, 0xD8, 0xFF, 0xD9>>
    }
    |> Map.merge(Map.new(overrides))
  end

  defp burst_pair(index) do
    %{
      capture_ns: 1_000_000_000 + index * 33_000_000,
      interval_ms: if(index > 0, do: 33.0),
      device_ms: 20.0 + index,
      sharpness: %{left: 100.0 + index, right: 90.0 + index},
      alignment: %{offset_rows: 0.25, band_offset_rows: [0.1, nil, 0.4]},
      metrics: [{:matched_percent, 90.0 + 2 * index, "%"}, {:mean_disparity_px, 12.0, "px"}],
      stage_ms: %{total: 30.0 + index, rectification: 5.0},
      frames: if(index < 2, do: frames(index))
    }
  end

  defp frames(index) do
    {grey_frame("left", index), grey_frame("right", index)}
  end

  defp grey_frame(label, index) do
    grey =
      :binary.list_to_bin(for pixel <- 0..(@width * @height - 1), do: rem(pixel * 3 + index, 256))

    %Frame{
      label: label,
      width: @width,
      height: @height,
      capture_ns: index * 33_000_000,
      grey: grey
    }
  end

  defp snapshot(depth_hz, cpu_percent, offset_max_ms) do
    %{
      cameras: %{
        left: %{present: true, fps: depth_hz},
        right: %{present: true, fps: depth_hz - 1.0}
      },
      sync: %{present: true, pairs: 30, offset_max_ms: offset_max_ms, offset_median_ms: 1.0},
      hailo: :absent,
      depth_hz: depth_hz,
      exporters: [],
      cpu_percent: cpu_percent,
      stereo_segment_percent: 55.0
    }
  end

  defp last_pair(disparity \\ nil, range \\ nil) do
    disparity =
      disparity || for index <- 0..47, do: if(rem(index, 5) == 0, do: -1.0, else: 1.0 + index / 4)

    image = fn offset ->
      rows =
        for row <- 0..(@height - 1), do: Enum.map(0..(@width - 1), &(row * @width + &1 + offset))

      Nx.tensor(rows, type: :u8)
    end

    %Pair{
      left_frame: grey_frame("left", 0),
      right_frame: grey_frame("right", 0),
      left: image.(0),
      right: image.(3),
      disparity_bytes: for(value <- disparity, into: <<>>, do: <<value::float-32-little>>),
      disparity_range: range,
      depth: for(mm <- @depth_mm, into: <<>>, do: <<mm::16-little>>)
    }
  end
end
