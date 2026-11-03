defmodule VisionCore.Stereo.SupervisorTest do
  # One test changes the app env the defn options default to.
  use ExUnit.Case, async: false

  alias VisionCore.Stereo.{Matcher, NativeSegment, NxSegment, Pipeline}
  alias VisionCore.Stereo.Supervisor, as: StereoSupervisor

  @moduletag :tmp_dir

  @left_options [calibration_path: "/rom/stereo_left.yaml"]
  @right_options [calibration_path: "/rom/stereo_right.yaml"]

  describe "use_stored_calibration/4" do
    test "leaves the sides alone without a store", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "stereo_left.yaml"), "")
      File.write!(Path.join(tmp_dir, "stereo_right.yaml"), "")

      assert StereoSupervisor.use_stored_calibration(@left_options, @right_options, nil, "stereo") ==
               {@left_options, @right_options}
    end

    test "keeps the shipped calibration while the store is empty", %{tmp_dir: tmp_dir} do
      {left, right} =
        StereoSupervisor.use_stored_calibration(@left_options, @right_options, tmp_dir, "stereo")

      assert left[:calibration_path] == "/rom/stereo_left.yaml"
      assert right[:calibration_path] == "/rom/stereo_right.yaml"
      assert left[:calibration_store_path] == Path.join(tmp_dir, "stereo_left.yaml")
      assert right[:calibration_store_path] == Path.join(tmp_dir, "stereo_right.yaml")
    end

    test "does not pair one stored side with a shipped one", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "stereo_left.yaml"), "")

      {left, right} =
        StereoSupervisor.use_stored_calibration(@left_options, @right_options, tmp_dir, "stereo")

      assert left[:calibration_path] == "/rom/stereo_left.yaml"
      assert right[:calibration_path] == "/rom/stereo_right.yaml"
    end

    test "uses the stored calibration once both sides are stored", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "stereo_left.yaml"), "")
      File.write!(Path.join(tmp_dir, "stereo_right.yaml"), "")

      {left, right} =
        StereoSupervisor.use_stored_calibration(@left_options, @right_options, tmp_dir, "stereo")

      assert left[:calibration_path] == Path.join(tmp_dir, "stereo_left.yaml")
      assert right[:calibration_path] == Path.join(tmp_dir, "stereo_right.yaml")
    end
  end

  describe "pipeline_options/1" do
    @stereo [
      driver: VisionCore.Camera.V4L2,
      left: [calibration_path: "/rom/stereo_left.yaml"],
      right: [calibration_path: "/rom/stereo_right.yaml"]
    ]

    # The defn options of the pipeline's NxSegment.
    defp defn_options(stereo) do
      [{NativeSegment, matcher: Matcher}, {NxSegment, defn_options: defn_options}] =
        StereoSupervisor.pipeline_options(stereo)[:backends]

      defn_options
    end

    test "gives the pipeline native backends on the Matcher, then Nx with the component's defn options" do
      opts =
        StereoSupervisor.pipeline_options(
          @stereo ++ [defn_options: [compiler: Nx.Defn.Evaluator]]
        )

      assert opts[:backends] == [
               {NativeSegment, matcher: Matcher},
               {NxSegment, defn_options: [compiler: Nx.Defn.Evaluator]}
             ]

      refute Keyword.has_key?(opts, :defn_options)
    end

    test "without them, config :vision_core, :nx_defn_options, else EXLA where it is loaded" do
      configured = Application.fetch_env!(:vision_core, :nx_defn_options)
      assert defn_options(@stereo) == configured
      assert defn_options(@stereo ++ [defn_options: nil]) == configured

      Application.delete_env(:vision_core, :nx_defn_options)
      on_exit(fn -> Application.put_env(:vision_core, :nx_defn_options, configured) end)
      assert defn_options(@stereo) == [compiler: EXLA]
    end

    test "gives the pipeline the component's backends, refusing defn options beside them" do
      backends = [{NxSegment, defn_options: [compiler: EXLA]}]
      opts = StereoSupervisor.pipeline_options(@stereo ++ [backends: backends])
      assert opts[:backends] == backends
      refute Keyword.has_key?(opts, :defn_options)

      assert StereoSupervisor.pipeline_options(@stereo ++ [backends: backends, defn_options: nil])[
               :backends
             ] == backends

      assert_raise ArgumentError, ~r/^:defn_options sets the default backends' NxSegment/, fn ->
        StereoSupervisor.pipeline_options(
          @stereo ++ [backends: backends, defn_options: [compiler: EXLA]]
        )
      end
    end
  end

  describe "reload_calibration/3" do
    test "starts the row correction over from the new calibration" do
      calibration = Path.expand("../../support/calibration", __DIR__)

      {:ok, pipeline} =
        Pipeline.start_link(
          name: :reload_row_offset,
          left_calibration_path: Path.join(calibration, "identity_left.yaml"),
          right_calibration_path: Path.join(calibration, "identity_right.yaml"),
          width: 64,
          height: 48,
          defn_options: [compiler: EXLA]
        )

      {:ok, _} = Pipeline.set_options(pipeline, :rectification, right_row_offset: 2.0)
      {:ok, _} = Pipeline.set_options(pipeline, :disparity, p1: 5)
      assert :ok = StereoSupervisor.reload_calibration(pipeline, "stereo")

      values = Map.new(Pipeline.stage_options(pipeline), &{&1.stage, &1.values})
      assert values.rectification.right_row_offset == 0.0
      assert values.disparity.p1 == 5
    end
  end

  describe "reload_stored_calibration/4" do
    test "waits for the second side before reloading", %{tmp_dir: tmp_dir} do
      left_path = Path.join(tmp_dir, "stereo_left.yaml")
      File.write!(left_path, "")

      assert StereoSupervisor.reload_stored_calibration(
               :no_backend,
               "stereo",
               left_path,
               Path.join(tmp_dir, "stereo_right.yaml")
             ) == :ok
    end
  end
end
