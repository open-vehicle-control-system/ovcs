defmodule VisionCore.Camera.PoseTest do
  use ExUnit.Case, async: false

  alias VisionCore.Camera.Pose
  alias VisionCore.Outputs

  @moduletag :tmp_dir

  defmodule Driver do
    def name_for(label), do: Module.concat(__MODULE__, label)
  end

  @pose %Pose{
    rotation: [
      0.9955536329797132,
      -0.05111739366074137,
      -0.07912000964501414,
      0.04871935302058673,
      0.9983013878798904,
      -0.0319493912045273,
      0.0806187850451108,
      0.02795265680426956,
      0.9963529798597648
    ],
    translation: [-0.12, 0.03, 1.0e-5]
  }

  defp write(tmp_dir, yaml) do
    path = Path.join(tmp_dir, "pose.yaml")
    File.write!(path, yaml)
    path
  end

  test "reads the rotation, row-major, and the translation in metres, as floats", %{
    tmp_dir: tmp_dir
  } do
    path =
      write(tmp_dir, """
      # From the rectified left optical frame to the camera's optical frame.
      rotation: [1, 0, 0, 0, 0.98, -0.2, 0, 0.2, 0.98]
      translation: [-0.1, 0.02, 1e-3]
      rms_px: 0.4
      """)

    assert Pose.load(path) ==
             {:ok,
              %Pose{
                rotation: [1.0, 0.0, 0.0, 0.0, 0.98, -0.2, 0.0, 0.2, 0.98],
                translation: [-0.1, 0.02, 0.001]
              }}
  end

  test "reads a pose YAML with comments and keys it does not use" do
    path = Path.expand("../../support/calibration/camera_pose_hq.yaml", __DIR__)

    assert {:ok, %Pose{rotation: [r00 | _] = rotation, translation: translation}} =
             Pose.load(path)

    assert length(rotation) == 9
    assert_in_delta r00, 0.9955536329797132, 1.0e-15
    assert translation == [-0.12, 0.03, 0.01]
  end

  test "a missing file is the reason File gives", %{tmp_dir: tmp_dir} do
    assert Pose.load(Path.join(tmp_dir, "none.yaml")) == {:error, :enoent}
  end

  test "refuses a rotation or translation of the wrong count, a missing one, or text", %{
    tmp_dir: tmp_dir
  } do
    for yaml <- [
          "rotation: [1, 0, 0, 0, 1, 0, 0, 0]\ntranslation: [0, 0, 0]\n",
          "rotation: [1, 0, 0, 0, 1, 0, 0, 0, 1]\ntranslation: [0, 0]\n",
          "translation: [0, 0, 0]\n",
          "rotation: [1, 0, 0, 0, 1, 0, 0, 0, 1]\ntranslation: [0, zero, 0]\n",
          "rotation: [1, 0, 0\n",
          "- 1\n"
        ] do
      assert {:error, {:malformed, reason}} = Pose.load(write(tmp_dir, yaml)), yaml
      assert is_binary(reason)
    end
  end

  describe "to_yaml/1" do
    test "reads back as the same pose, element for element" do
      assert @pose |> Pose.to_yaml() |> Pose.parse() == {:ok, @pose}
    end
  end

  test "distance_m/1 is the distance between the two cameras' optical centres" do
    assert_in_delta Pose.distance_m(%Pose{@pose | translation: [-0.12, 0.03, 0.04]}),
                    0.13,
                    1.0e-12
  end

  defp config(camera_options),
    do: %VisionCore.Config{components: [{:camera, [name: :hq, driver: Driver] ++ camera_options}]}

  defp store(tmp_dir) do
    built_in = Path.join(tmp_dir, "hq_pose.yaml")
    store_dir = Path.join(tmp_dir, "store")
    {built_in, store_dir, Path.join(store_dir, "camera_hq_pose.yaml")}
  end

  describe "in_use/2" do
    test "reads the built-in pose, with nothing to go back to", %{tmp_dir: tmp_dir} do
      {built_in, store_dir, _stored} = store(tmp_dir)
      File.write!(built_in, Pose.to_yaml(@pose))

      assert {:ok, in_use} =
               Pose.in_use(config(pose: built_in, calibration_store_dir: store_dir), :hq)

      assert in_use.source == :built_in
      assert in_use.stored_at == nil
      refute in_use.can_reset
      assert in_use.path == built_in
      assert in_use.pose == @pose
      assert in_use.yaml == Pose.to_yaml(@pose)
      assert in_use.error == nil
    end

    test "has no pose without a file, or without a :pose", %{tmp_dir: tmp_dir} do
      {built_in, _store_dir, _stored} = store(tmp_dir)

      for config <- [config(pose: built_in), config([])] do
        assert {:ok, %{source: :none, can_reset: false, pose: nil, yaml: nil, error: nil}} =
                 Pose.in_use(config, :hq)
      end
    end

    test "says why a file it cannot parse gives no pose", %{tmp_dir: tmp_dir} do
      {built_in, _store_dir, _stored} = store(tmp_dir)
      File.write!(built_in, "rotation: [1, 0]\n")

      assert {:ok, %{source: :none, pose: nil, error: error}} =
               Pose.in_use(config(pose: built_in), :hq)

      assert error =~ built_in
      assert error =~ "rotation"
    end

    test "does not know a camera the configuration has not" do
      assert Pose.in_use(config([]), :usb) == {:error, :not_found}
    end
  end

  describe "commit/3" do
    test "writes the pose to the store, which takes precedence, and tells the change",
         %{tmp_dir: tmp_dir} do
      {built_in, store_dir, stored} = store(tmp_dir)
      File.write!(built_in, Pose.to_yaml(%Pose{@pose | translation: [0.0, 0.0, 0.0]}))
      config = config(pose: built_in, calibration_store_dir: store_dir)
      :ok = Outputs.subscribe(Pose.changed_key(:hq))

      assert :ok = Pose.commit(config, :hq, @pose)

      assert_receive {:"$gen_cast", {:camera_pose_changed, :hq}}
      assert Pose.load(stored) == {:ok, @pose}
      refute File.exists?(stored <> ".tmp")
      assert [%{pose_path: ^stored}] = VisionCore.Camera.Unit.settings(config)

      assert {:ok, in_use} = Pose.in_use(config, :hq)
      assert in_use.source == :stored
      assert %DateTime{} = in_use.stored_at
      assert in_use.can_reset
      assert in_use.pose == @pose
    end

    test "without a store, writes the camera's :pose path", %{tmp_dir: tmp_dir} do
      {built_in, _store_dir, _stored} = store(tmp_dir)

      assert :ok = Pose.commit(config(pose: built_in), :hq, @pose)
      assert Pose.load(built_in) == {:ok, @pose}
    end

    test "waits for a commit or a reset of the same camera's pose to end", %{tmp_dir: tmp_dir} do
      {_built_in, store_dir, stored} = store(tmp_dir)
      config = config(calibration_store_dir: store_dir)
      lock = {{Pose, :hq}, self()}
      true = :global.set_lock(lock, [node()])

      commit = Task.async(fn -> Pose.commit(config, :hq, @pose) end)
      refute Task.yield(commit, 100)
      refute File.exists?(stored)

      true = :global.del_lock(lock, [node()])
      assert Task.await(commit) == :ok
      assert File.exists?(stored)
    end

    test "refuses a camera with nowhere to write, and one it does not know" do
      assert {:error, reason} = Pose.commit(config([]), :hq, @pose)
      assert reason =~ "no pose path"
      assert Pose.commit(config([]), :usb, @pose) == {:error, :not_found}
    end
  end

  describe "reset/2" do
    test "removes the stored pose, back to the built-in one, and tells the change",
         %{tmp_dir: tmp_dir} do
      {built_in, store_dir, stored} = store(tmp_dir)
      File.write!(built_in, Pose.to_yaml(@pose))
      config = config(pose: built_in, calibration_store_dir: store_dir)
      :ok = Pose.commit(config, :hq, %Pose{@pose | translation: [0.0, 0.0, 0.0]})
      :ok = Outputs.subscribe(Pose.changed_key(:hq))

      assert :ok = Pose.reset(config, :hq)

      assert_receive {:"$gen_cast", {:camera_pose_changed, :hq}}
      refute File.exists?(stored)
      assert {:ok, %{source: :built_in, pose: @pose}} = Pose.in_use(config, :hq)
    end

    test "refuses with nothing stored, without a store, or without a built-in pose",
         %{tmp_dir: tmp_dir} do
      {built_in, store_dir, stored} = store(tmp_dir)
      File.write!(built_in, Pose.to_yaml(@pose))

      assert {:error, "nothing is stored"} =
               Pose.reset(config(pose: built_in, calibration_store_dir: store_dir), :hq)

      assert {:error, "the camera has no calibration store"} =
               Pose.reset(config(pose: built_in), :hq)

      no_built_in = config(calibration_store_dir: store_dir)
      :ok = Pose.commit(no_built_in, :hq, @pose)

      assert {:error, "there is no built-in pose to return to"} = Pose.reset(no_built_in, :hq)
      assert File.exists?(stored)
    end
  end
end
