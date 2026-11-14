defmodule VisionCore.Stereo.BenchTest do
  use ExUnit.Case, async: false

  alias VisionCore.Stereo.{Bench, Pipeline}
  alias VisionCore.Stereo.Stage.{Disparity, Quality, SpeckleFilter}

  # A vehicle's stages, as its composer lists them.
  @vehicle_stages Pipeline.default_stages(
                    disparity: [num_disparities: 128, search: "coarse_to_fine", coarse_paths: 3]
                  )

  describe "stages/1" do
    test "times the default stages unless given others" do
      assert Bench.stages([]) == Pipeline.default_stages()
    end

    test "keeps the given stages' options under the Disparity options and overrides given" do
      stages =
        Bench.stages(
          stages: @vehicle_stages,
          disparity: [paths: 8],
          overrides: [disparity: [p2: 79], speckle_filter: [max_diff: 2.0]]
        )

      assert stages[Disparity] == [
               num_disparities: 128,
               search: "coarse_to_fine",
               coarse_paths: 3,
               paths: 8,
               p2: 79
             ]

      assert stages[SpeckleFilter] == [max_diff: 2.0]
    end

    test "leaves out the stages dropped" do
      stages = Bench.stages(stages: @vehicle_stages, drop: [:speckle_filter, :quality])

      refute List.keymember?(stages, SpeckleFilter, 0)
      refute List.keymember?(stages, Quality, 0)
      assert length(stages) == length(@vehicle_stages) - 2
    end
  end

  describe "parse_overrides/2" do
    test "reads each value as its setting's type" do
      texts = ["disparity.paths=3", "disparity.uniqueness=1.5", "disparity.search=full"]

      assert Bench.parse_overrides(texts, @vehicle_stages) ==
               {:ok, [disparity: [paths: 3, uniqueness: 1.5, search: "full"]]}
    end

    test "refuses a stage the list lacks, a setting its stage lacks, a value of another type" do
      for text <- ["median_filter.window=5", "quality.window=5", "disparity.paths=many", "paths"] do
        assert {:error, reason} = Bench.parse_overrides([text], @vehicle_stages)
        assert reason =~ text
      end
    end
  end

  describe "parse_stage_names/2" do
    test "reads the names of the list's stages" do
      assert Bench.parse_stage_names(["speckle_filter", "quality"], @vehicle_stages) ==
               {:ok, [:speckle_filter, :quality]}
    end

    test "refuses a name no stage has" do
      assert {:error, "no stage named median_filter;" <> _names} =
               Bench.parse_stage_names(["median_filter"], @vehicle_stages)
    end
  end

  describe "drm_gpu_ns/1" do
    defp fdinfo(client_id, gpu_ns),
      do:
        "pos:\t0\ndrm-driver:\tmsm\ndrm-client-id:\t#{client_id}\ndrm-engine-gpu:\t#{gpu_ns} ns\n"

    test "sums the clients' GPU time, a client with several descriptors once" do
      fdinfos = [fdinfo(7, 1_000), fdinfo(7, 1_000), fdinfo(9, 250)]

      assert Bench.drm_gpu_ns(fdinfos) == 1_250
    end

    test "is nil when no descriptor reports the GPU engine" do
      assert Bench.drm_gpu_ns([]) == nil
      assert Bench.drm_gpu_ns(["drm-driver:\ti915\ndrm-engine-render:\t500 ns\n"]) == nil
    end
  end

  # These compile the stages for a board's GPU, through the IREE compiler and Vulkan.
  describe "on a GPU" do
    @describetag :vulkan
    @describetag :tmp_dir

    test "a prepared benchmark runs from its cache and matches EXLA's outputs", %{tmp_dir: dir} do
      :ok =
        Bench.prepare(dir,
          board: "c100",
          size: {192, 108},
          disparity: [num_disparities: 64, paths: 3],
          pairs: 3
        )

      assert [_ | _] = Path.wildcard(Path.join([dir, "cache", "*"]))
      report = Bench.run(dir)

      for key <- ~w(left right disparity depth cloud),
          do: assert(report =~ ~r/^#{key}: 0\/\d+ differ/m, report)

      assert [_, times] = Regex.run(~r/us per pair: \[([^\]]*)\]/, report)
      assert times |> String.split(", ") |> length() == 3
      assert report =~ ~r/^BENCH total_ms=\S+ dispatch_ms=\S+ collect_ms=\S+ gpu_ms=\S+/m
    end

    @tag :stereo_match
    test "a native benchmark computes the stages in stereo_match, as EXLA does", %{tmp_dir: dir} do
      :ok =
        Bench.prepare(dir,
          board: "ventuno_q",
          compute: :native,
          size: {192, 108},
          disparity: [num_disparities: 64, paths: 3],
          pairs: 2
        )

      assert Path.wildcard(Path.join([dir, "cache", "*"])) == []
      report = Bench.run(dir)

      for key <- ~w(left right disparity depth cloud),
          do: assert(report =~ ~r/^#{key}: 0\/\d+ differ/m, report)

      assert report =~ "us per pair: ["
    end
  end
end
