defmodule VisionCore.Debug.CompareTest do
  use ExUnit.Case, async: false

  alias VisionCore.Debug.{Compare, Export, Png}
  alias VisionCore.Firmware
  alias VisionCore.Parameters.Parameter
  alias VisionCore.Stereo.Pair
  alias VisionCore.TestPng

  @moduletag :tmp_dir

  # Pixel 0 differs a little, 1 is equal, 2 differs beyond the grey scale, 3 is matched
  # in A only, 4 in B only, the rest in neither; pixel 6 has a depth but no disparity.
  @disparity_a [5.0, 3.0, 2.0, 4.0, -1.0] ++ List.duplicate(-1.0, 7)
  @disparity_b [5.5, 3.0, 12.0, -1.0, 6.0] ++ List.duplicate(-1.0, 7)
  @depth_a [1_000, 2_000, 500, 700, 0, 0, 100, 0, 0, 0, 0, 0]
  @depth_b [1_100, 2_000, 3_000, 0, 800, 0, 102, 0, 0, 0, 0, 0]

  test "lists the parameters that differ" do
    a = export(parameters: [parameter("stereo.block_size", 5), parameter("camera.gain", 1.5)])

    b =
      export(
        parameters: [
          parameter("stereo.block_size", 7),
          parameter("camera.gain", 1.5),
          parameter("camera.exposure_us", 4_000)
        ]
      )

    assert %{parameters: [{"camera.exposure_us", nil, 4_000}, {"stereo.block_size", 5, 7}]} =
             Compare.compare(a, b)

    assert %{parameters: []} = Compare.compare(a, a)
  end

  test "marks a figure change within the spread" do
    a = export(matched: [90.0, 92.0, 94.0], sharpness: [100.0, 101.0, 102.0], depth_hz: [29, 31])
    b = export(matched: [91.0, 93.0, 95.0], sharpness: [110.0, 111.0, 112.0], depth_hz: [49, 51])

    %{figures: figures} = Compare.compare(a, b)

    assert %{
             name: "matchedPercent",
             a: %{mean: 92.0, min: 90.0, max: 94.0, std: std, n: 3},
             b: %{mean: 93.0, n: 3},
             delta: 1.0,
             within_spread: true
           } = figure(figures, "matchedPercent")

    assert_in_delta std, :math.sqrt(8 / 3), 1.0e-9
    assert %{delta: 10.0, within_spread: false} = figure(figures, "sharpnessLeft")
    assert %{within_spread: true} = mean_disparity = figure(figures, "meanDisparityPx")
    assert mean_disparity.delta == 0.0
  end

  test "judges a change against the larger of the two spreads" do
    wide_a = export(matched: [90.0, 92.0, 94.0], sharpness: [100.0, 100.0, 100.0])
    wide_b = export(matched: [93.0, 93.0, 93.0], sharpness: [99.0, 101.0, 105.0])

    %{figures: figures} = Compare.compare(wide_a, wide_b)

    assert %{a: %{std: wide}, b: %{std: narrow}, delta: 1.0, within_spread: true} =
             figure(figures, "matchedPercent")

    assert narrow == 0.0 and wide > 1.0

    assert %{a: %{std: narrow}, b: %{std: wide}, within_spread: true} =
             sharpness = figure(figures, "sharpnessLeft")

    assert narrow == 0.0 and sharpness.delta > 1.0 and sharpness.delta < wide

    beyond_b = export(matched: [100.0, 100.0, 100.0])

    assert %{delta: 8.0, within_spread: false} =
             figure(Compare.compare(wide_a, beyond_b).figures, "matchedPercent")
  end

  test "takes a change on fewer than three samples for within the spread" do
    a = export(interval_ms: 33.0, depth_hz: [29, 31])
    b = export(interval_ms: 133.0, depth_hz: [49, 51])

    %{figures: figures} = Compare.compare(a, b)

    assert %{a: %{n: 2}, b: %{n: 2}, delta: 100.0, within_spread: true} =
             figure(figures, "intervalMs")

    assert %{a: %{n: 2}, delta: 20.0, within_spread: true} = figure(figures, "depthHz")
    assert figures == Enum.sort_by(figures, & &1.name)
  end

  test "never judges a figure of the status snapshots, however many samples it has" do
    a = export(depth_hz: [29, 30, 31, 30], cpu_percent: [40.0, 41.0, 40.0, 41.0])

    b =
      export(
        depth_hz: [49, 50, 51, 50],
        cpu_percent: [40.0, 41.0, 40.0, 41.0],
        matched: [100.0, 100.0, 100.0]
      )

    %{figures: figures} = Compare.compare(a, b)

    assert %{a: %{n: 4}, b: %{n: 4}, delta: 20.0, status: true, within_spread: true} =
             figure(figures, "depthHz")

    assert %{a: %{n: 4}, status: true} = figure(figures, "cpuPercent")
    assert %{delta: 8.0, status: false, within_spread: false} = figure(figures, "matchedPercent")
  end

  test "compares the stages' timings" do
    a = export(total_ms: [30.0, 31.0, 32.0])
    b = export(total_ms: [40.0, 41.0, 42.0])

    assert %{
             timings: [
               %{stage: "rectification", a_median: 5.0, b_median: 5.0, a_p95: 5.0, b_p95: 5.0},
               %{stage: "total", a_median: 31.0, b_median: 41.0, a_p95: 32.0, b_p95: 42.0}
             ]
           } = Compare.compare(a, b)
  end

  test "tells the exports apart by their manifests" do
    a = export(change_age_ms: 2_150, changes_during_burst: 0, firmware: firmware("abc123"))

    b =
      export_b(
        hostname: "unit-2",
        change_age_ms: nil,
        changes_during_burst: 1,
        status_available: false,
        snapshots: [],
        firmware: firmware("def456")
      )

    assert %{exports: %{a: export_a, b: export_b}} = Compare.compare(a, b)

    assert export_a == %{
             hostname: "unit-1",
             time: "2026-11-03T14:05:09Z",
             firmware: "abc123",
             change_age_ms: 2_150,
             changes_during_burst: 0,
             status_available: true
           }

    assert export_b == %{
             hostname: "unit-2",
             time: "2026-11-04T08:00:00Z",
             firmware: "def456",
             change_age_ms: nil,
             changes_during_burst: 1,
             status_available: false
           }
  end

  test "lists the figures and stages only one export has" do
    a = export(cpu_percent: [40.0, 41.0], extra_stage: %{decode: 3.0})
    b = export(extra_stage: %{encode: 2.0})

    report = Compare.compare(a, b)

    assert report.figures_only_in == %{a: ["cpuPercent"], b: []}
    assert report.timings_only_in == %{a: ["decode"], b: ["encode"]}
    refute Enum.any?(report.figures, &(&1.name == "cpuPercent"))
    refute Enum.any?(report.timings, &(&1.stage in ["decode", "encode"]))

    assert %{figures_only_in: %{a: [], b: []}, timings_only_in: %{a: [], b: []}} =
             Compare.compare(a, a)
  end

  test "counts the pixels matched in one export only" do
    assert %{pixels: pixels} = Compare.compare(export(), export_b())

    assert %{both: 3, a_only: 1, b_only: 1} = pixels
    assert_in_delta pixels.mean_abs_disparity_px, 3.5, 1.0e-9
    assert_in_delta pixels.mean_abs_depth_mm, 650.5, 1.0e-9
  end

  test "has no mean where the exports share no matched pixel" do
    none = List.duplicate(-1.0, 12)
    no_depth = List.duplicate(0, 12)

    assert %{pixels: %{both: 0, mean_abs_disparity_px: nil, mean_abs_depth_mm: nil}} =
             Compare.compare(
               export(disparity: none, depth: no_depth),
               export(disparity: none, depth: no_depth)
             )
  end

  test "makes difference images of the size of the pair" do
    assert %{images: images} = Compare.compare(export(), export_b())

    assert Map.keys(images) == ["depth-diff.png", "disparity-diff.png"]

    disparity = TestPng.decode!(images["disparity-diff.png"])
    assert %{width: 4, height: 3, bit_depth: 8, colour_type: 0} = disparity
    assert disparity.pixels == <<16, 0, 255, 255, 255, 0, 0, 0, 0, 0, 0, 0>>

    depth = TestPng.decode!(images["depth-diff.png"])
    assert %{width: 4, height: 3, bit_depth: 8, colour_type: 0} = depth
    assert depth.pixels == <<25, 0, 255, 255, 255, 0, 1, 0, 0, 0, 0, 0>>
  end

  test "refuses exports whose images differ in size" do
    assert_raise ArgumentError, ~r/4x3.*6x2/, fn ->
      Compare.compare(export(), export(size: {6, 2}))
    end
  end

  test "refuses a file that is not an export" do
    {:ok, {_name, empty}} = :zip.create(~c"empty.zip", [{~c"empty/README.md", "text"}], [:memory])

    assert_raise ArgumentError, ~r/export B: manifest\.json is missing/, fn ->
      Compare.compare(export(), empty)
    end

    assert_raise ArgumentError, ~r/export A: not a readable zip archive/, fn ->
      Compare.compare("not a zip", export())
    end
  end

  test "names the file and the problem of a malformed export" do
    short_disparity = <<1.0::float-32-little>>

    cases = [
      {%{"manifest.json" => "{not json"}, "manifest.json is not valid JSON"},
      {%{"manifest.json" => ~s({"hostname": "unit-1"})}, "manifest.json has no imageSize"},
      {%{"manifest.json" => ~s({"imageSize": {"width": 4}})}, "manifest.json has no imageSize"},
      {%{"parameters.json" => ~s({"id": "a"})}, "parameters.json is not a list of parameters"},
      {%{"figures.json" => ~s({"pairs": []})}, "figures.json has no summary"},
      {%{"figures.json" => ~s({"summary": {"matchedPercent": {"mean": 1}}})},
       "figures.json summary of matchedPercent lacks"},
      {%{"timings.json" => ~s({"total": {"median": 1}})}, "timings.json stage total lacks"},
      {%{"last/depth.png" => nil}, "last/depth.png is missing"},
      {%{"last/depth.png" => "not a png"}, "last/depth.png cannot be read"},
      {%{"last/disparity.f32" => short_disparity}, "last/disparity.f32 does not fill a 4x3 image"}
    ]

    for {changes, problem} <- cases do
      message = "export B: " <> problem

      error =
        assert_raise ArgumentError, fn ->
          Compare.compare(export(), altered(export(), changes))
        end

      assert error.message =~ message
    end
  end

  describe "mix vision_core.compare_exports" do
    test "the mix task writes the images and prints the tables", %{tmp_dir: directory} do
      a_path = Path.join(directory, "a.zip")
      b_path = Path.join(directory, "b.zip")
      out = Path.join(directory, "out")

      File.write!(
        a_path,
        export(
          parameters: [parameter("stereo.block_size", 5)],
          cpu_percent: [40.0, 41.0],
          extra_stage: %{decode: 3.0},
          change_age_ms: 2_150
        )
      )

      File.write!(
        b_path,
        export_b(
          hostname: "unit-2",
          changes_during_burst: 1,
          parameters: [parameter("stereo.block_size", 7)],
          matched: [91.0, 93.0, 95.0],
          sharpness: [110.0, 111.0, 112.0]
        )
      )

      output =
        ExUnit.CaptureIO.capture_io(fn ->
          Mix.Tasks.VisionCore.CompareExports.run([a_path, b_path, "--out", out])
        end)

      assert output =~ ~r/A\s+unit-1\s+2026-11-03T14:05:09Z.*2150 ms\s+0\s+available\s+\S*a\.zip/

      assert output =~
               ~r/B\s+unit-2\s+2026-11-04T08:00:00Z.*none recorded\s+1\s+available\s+\S*b\.zip/

      assert output =~ ~r/stereo\.block_size\s+5\s+7/
      assert output =~ ~r/Figures only in A: cpuPercent/
      assert output =~ ~r/Stages only in A: decode/
      assert output =~ ~r/matchedPercent.*within spread/
      assert output =~ ~r/sharpnessLeft.*beyond spread/
      assert output =~ ~r/intervalMs.*too few samples/
      assert output =~ ~r/total\s+31\.0\s+31\.0/
      assert output =~ ~r/both\s+3/
      assert output =~ out

      assert {:ok, %{width: 4, height: 3, bit_depth: 8, colour: :grey}} =
               out |> Path.join("disparity-diff.png") |> File.read!() |> Png.decode()

      assert {:ok, %{width: 4, height: 3}} =
               out |> Path.join("depth-diff.png") |> File.read!() |> Png.decode()
    end

    test "prints small figures with their significant digits, and status figures unjudged",
         %{tmp_dir: directory} do
      a_path = Path.join(directory, "a.zip")
      b_path = Path.join(directory, "b.zip")
      status = [depth_hz: [29, 30, 31, 30], cpu_percent: [nil, nil, nil, nil]]
      File.write!(a_path, export([sharpness: [0.004588, 0.004592, 0.004596]] ++ status))
      File.write!(b_path, export([sharpness: [0.005374, 0.005378, 0.005382]] ++ status))

      output = compare_output(a_path, b_path, directory)

      assert output =~
               ~r/sharpnessLeft\s+0\.004592\s+3\.266e-06\s+3\s+0\.005378\s+3\.266e-06\s+3\s+0\.000786\s+beyond spread/

      assert output =~
               ~r/depthHz\s+30\.0\s+0\.7071\s+4\s+30\.0\s+0\.7071\s+4\s+0\s+status figure, not judged/

      assert compare_output(b_path, a_path, directory) =~ ~r/sharpnessLeft.*\s-0\.000786\s/
    end

    test "turns a malformed export into an error naming the problem", %{tmp_dir: directory} do
      good = Path.join(directory, "good.zip")
      bad = Path.join(directory, "bad.zip")
      File.write!(good, export())
      File.write!(bad, altered(export(), %{"figures.json" => "{}"}))

      assert_raise Mix.Error, ~r/export B: figures\.json has no summary/, fn ->
        Mix.Tasks.VisionCore.CompareExports.run([good, bad, "--out", directory])
      end
    end

    test "says what it needs when it is not given two exports" do
      assert_raise Mix.Error, ~r/mix vision_core\.compare_exports A\.zip B\.zip/, fn ->
        Mix.Tasks.VisionCore.CompareExports.run(["only-one.zip"])
      end
    end

    test "says which file it cannot read", %{tmp_dir: directory} do
      missing = Path.join(directory, "missing.zip")

      assert_raise Mix.Error, ~r/cannot read .*missing\.zip/, fn ->
        Mix.Tasks.VisionCore.CompareExports.run([missing, missing, "--out", directory])
      end
    end
  end

  defp compare_output(a_path, b_path, directory) do
    ExUnit.CaptureIO.capture_io(fn ->
      Mix.Tasks.VisionCore.CompareExports.run([a_path, b_path, "--out", directory])
    end)
  end

  defp figure(figures, name), do: Enum.find(figures, &(&1.name == name))

  defp parameter(id, value), do: %Parameter{id: id, value: value, saved: nil, state: :builtin}

  defp firmware(revision),
    do: %Firmware{
      revision: revision,
      target: "rpi5",
      nerves_system: "vision_rpi5",
      nerves_system_version: "1.0.0"
    }

  defp altered(zip, changes) do
    {:ok, entries} = :zip.unzip(zip, [:memory])
    directory = entries |> hd() |> elem(0) |> List.to_string() |> Path.split() |> hd()

    kept =
      for {name, content} <- entries,
          not Map.has_key?(changes, relative(name, directory)),
          do: {name, content}

    replaced =
      for {file, content} <- changes,
          content != nil,
          do: {String.to_charlist(directory <> "/" <> file), content}

    {:ok, {_name, altered}} = :zip.create(~c"altered.zip", kept ++ replaced, [:memory])
    altered
  end

  defp relative(name, directory),
    do: name |> List.to_string() |> String.replace_prefix(directory <> "/", "")

  defp export(options \\ []) do
    {_filename, zip} = options |> recording() |> Export.build()
    zip
  end

  defp export_b(options \\ []) do
    [time: ~U[2026-11-04 08:00:00Z], disparity: @disparity_b, depth: @depth_b]
    |> Keyword.merge(options)
    |> export()
  end

  defp recording(options) do
    {width, height} = Keyword.get(options, :size, {4, 3})
    matched = Keyword.get(options, :matched, [90.0, 92.0, 94.0])
    sharpness = Keyword.get(options, :sharpness, [100.0, 101.0, 102.0])
    total_ms = Keyword.get(options, :total_ms, [30.0, 31.0, 32.0])
    interval_ms = Keyword.get(options, :interval_ms, 33.0)
    disparity = Keyword.get(options, :disparity, @disparity_a)
    depth = Keyword.get(options, :depth, @depth_a)
    extra_stage = Keyword.get(options, :extra_stage, %{})
    depth_hz = Keyword.get(options, :depth_hz, [29, 31])
    cpu_percent = Keyword.get(options, :cpu_percent, [nil, nil])

    %{
      hostname: Keyword.get(options, :hostname, "unit-1"),
      time: Keyword.get(options, :time, ~U[2026-11-03 14:05:09Z]),
      firmware: Keyword.get(options, :firmware),
      parameters: Keyword.get(options, :parameters, [parameter("stereo.block_size", 5)]),
      configuration: %{"components" => []},
      calibration: %{left: "left\n", right: "right\n"},
      pairs:
        [matched, sharpness, total_ms]
        |> Enum.zip()
        |> Enum.with_index()
        |> Enum.map(fn {{matched, sharpness, total_ms}, index} ->
          burst_pair(index, matched, sharpness, total_ms, interval_ms, extra_stage)
        end),
      last_pair: last_pair(width, height, disparity, depth),
      snapshots:
        Keyword.get(options, :snapshots, Enum.zip_with(depth_hz, cpu_percent, &snapshot/2)),
      detections: nil,
      change_age_ms: Keyword.get(options, :change_age_ms),
      changes_during_burst: Keyword.get(options, :changes_during_burst, 0),
      status_available: Keyword.get(options, :status_available, true)
    }
  end

  defp burst_pair(index, matched, sharpness, total_ms, interval_ms, extra_stage) do
    %{
      capture_ns: 1_000_000_000 + index * 33_000_000,
      interval_ms: if(index > 0, do: interval_ms),
      device_ms: 20.0,
      sharpness: %{left: sharpness, right: 90.0},
      alignment: %{offset_rows: 0.25, band_offset_rows: []},
      metrics: [{:matched_percent, matched, "%"}, {:mean_disparity_px, 12.0, "px"}],
      stage_ms: Map.merge(%{total: total_ms, rectification: 5.0}, extra_stage),
      frames: nil
    }
  end

  defp snapshot(depth_hz, cpu_percent),
    do: %{depth_hz: depth_hz, cpu_percent: cpu_percent, stereo_segment_percent: 50.0}

  defp last_pair(width, height, disparity, depth) do
    image = Nx.broadcast(Nx.tensor(0, type: :u8), {height, width})

    %Pair{
      left_frame: nil,
      right_frame: nil,
      left: image,
      right: image,
      disparity_bytes: for(value <- disparity, into: <<>>, do: <<value::float-32-little>>),
      depth: for(millimetres <- depth, into: <<>>, do: <<millimetres::16-little>>)
    }
  end
end
