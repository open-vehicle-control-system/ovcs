defmodule Mix.Tasks.VisionCore.NxCacheTest do
  use ExUnit.Case, async: false

  alias VisionCore.Stereo.{NxSegment, Pipeline, Supervisor}

  @moduletag :vulkan
  @moduletag :tmp_dir
  @moduletag timeout: 600_000

  defmodule Composer do
    @calibration Path.expand("../../support/calibration", __DIR__)

    def config(:target) do
      %VisionCore.Config{
        zenoh_endpoint_ip: "127.0.0.1",
        components: [
          stereo: [
            driver: VisionCore.Camera.V4L2,
            width: 192,
            height: 108,
            match_width: 96,
            match_height: 54,
            stages: Pipeline.default_stages(),
            defn_options: NxSegment.c100_defn_options("unused"),
            left: [calibration_path: Path.join(@calibration, "identity_left.yaml")],
            right: [calibration_path: Path.join(@calibration, "identity_right.yaml")]
          ]
        ]
      }
    end
  end

  defp run_task(dir) do
    ExUnit.CaptureIO.capture_io(fn ->
      Mix.Tasks.VisionCore.NxCache.run(["--composer", inspect(Composer), "--out", dir])
    end)
  end

  test "caches every module once, as the device finds them", %{tmp_dir: dir} do
    run_task(dir)
    modules = Path.wildcard(Path.join(dir, "*.nxiree"))

    # The segment and Quality's statistics.
    assert length(modules) == 2

    run_task(dir)
    assert Path.wildcard(Path.join(dir, "*.nxiree")) == modules

    # Started as on the device, loading what the task wrote.
    {:ok, [device | _]} = NxIREE.list_devices("vulkan")
    {:stereo, stereo} = List.keyfind(Composer.config(:target).components, :stereo, 0)

    defn_options =
      dir |> NxSegment.c100_defn_options() |> Keyword.put(:iree_runtime_options, device: device)

    opts =
      stereo
      |> Supervisor.pipeline_options()
      |> Keyword.merge(defn_options: defn_options, name: :nx_cache_test_pipeline)

    {:ok, pipeline} = Pipeline.start_link(opts)
    GenServer.stop(pipeline)

    assert Path.wildcard(Path.join(dir, "*.nxiree")) == modules
  end
end
