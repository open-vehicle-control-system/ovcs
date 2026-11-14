defmodule VisionCore.Stereo.CalibrationTest do
  # Each test publishes under a prefix of its own.
  use ExUnit.Case, async: true

  alias VisionCore.Outputs
  alias VisionCore.Ros2.CameraCalibration
  alias VisionCore.Stereo.Calibration

  @moduletag :tmp_dir
  @moduletag :capture_log
  @fixtures Path.expand("../../support/calibration", __DIR__)

  # Names the cameras, which need not be running.
  defmodule Camera do
    def name_for(label), do: Module.concat(__MODULE__, label)
  end

  defp prefix(test), do: "unit_#{:erlang.phash2(test)}"

  # A stereo unit whose built-in calibrations are in `<tmp_dir>/built_in`.
  defp config(tmp_dir, prefix, stereo \\ []) do
    %VisionCore.Config{
      components: [
        stereo:
          Keyword.merge(
            [
              driver: Camera,
              prefix: prefix,
              calibration_dir: Path.join(tmp_dir, "built_in"),
              left: [],
              right: []
            ],
            stereo
          )
      ]
    }
  end

  defp with_store(config, tmp_dir) do
    update_in(
      config.components[:stereo],
      &Keyword.put(&1, :calibration_store_dir, store(tmp_dir))
    )
  end

  defp store(tmp_dir), do: Path.join(tmp_dir, "store")

  defp install_built_in(tmp_dir, prefix) do
    File.mkdir_p!(Path.join(tmp_dir, "built_in"))

    for side <- ["left", "right"] do
      File.cp!(
        Path.join(@fixtures, "stereo_#{side}.yaml"),
        Path.join(tmp_dir, "built_in/#{prefix}_#{side}.yaml")
      )
    end
  end

  defp distorted do
    %{
      left: CameraCalibration.load!(Path.join(@fixtures, "distorted_left.yaml")),
      right: CameraCalibration.load!(Path.join(@fixtures, "distorted_right.yaml"))
    }
  end

  # Records each reload in the test's mailbox and answers `answer`.
  defp reload(answer) do
    test = self()

    fn paths ->
      send(test, {:reloaded, paths})
      answer
    end
  end

  # The options of a commit to a unit whose pipeline runs, or does not.
  defp running(opts), do: [pipeline_running?: fn -> true end] ++ opts
  defp stopped(opts), do: [pipeline_running?: fn -> false end] ++ opts

  defp reloading(answer), do: running(reload: reload(answer))

  defp subscribe(prefix), do: :ok = Outputs.subscribe(Calibration.changed_key(prefix))

  describe "with a store" do
    setup %{tmp_dir: tmp_dir, test: test} do
      prefix = prefix(test)
      install_built_in(tmp_dir, prefix)
      subscribe(prefix)
      %{prefix: prefix, config: tmp_dir |> config(prefix) |> with_store(tmp_dir)}
    end

    test "commit/3 stores both sides, reloads from the store and tells the change",
         %{tmp_dir: tmp_dir, prefix: prefix, config: config} do
      left_store = Path.join(store(tmp_dir), "#{prefix}_left.yaml")
      right_store = Path.join(store(tmp_dir), "#{prefix}_right.yaml")

      assert :ok = Calibration.commit(config, distorted(), reloading(:ok))

      assert File.read!(left_store) =~ "camera_name: #{prefix}_left"
      assert File.read!(right_store) =~ "camera_name: #{prefix}_right"

      assert_received {:reloaded,
                       [left_calibration_path: ^left_store, right_calibration_path: ^right_store]}

      assert_received {:"$gen_cast", {:stereo_calibration_changed, ^prefix}}

      assert {:ok, in_use} = Calibration.in_use(config)
      assert in_use.source == :stored
      assert in_use.can_reset
      assert %DateTime{} = in_use.stored_at
      assert in_use.prefix == prefix
      assert in_use.left.path == left_store
      assert in_use.left.calibration == distorted().left
      assert in_use.left.yaml == File.read!(left_store)
    end

    test "commit/3 puts back what the store held when the stereo unit refuses, and tells nothing",
         %{tmp_dir: tmp_dir, prefix: prefix, config: config} do
      left_store = Path.join(store(tmp_dir), "#{prefix}_left.yaml")
      right_store = Path.join(store(tmp_dir), "#{prefix}_right.yaml")

      assert {:error, message} =
               Calibration.commit(config, distorted(), reloading({:error, :bad_calibration}))

      assert message =~ "bad_calibration"
      refute File.exists?(left_store)
      refute File.exists?(right_store)

      File.write!(left_store, "stored left")
      File.write!(right_store, "stored right")

      assert {:error, _message} =
               Calibration.commit(
                 config,
                 distorted(),
                 running(reload: fn _paths -> raise "no fit" end)
               )

      assert File.read!(left_store) == "stored left"
      assert File.read!(right_store) == "stored right"
      refute_received {:"$gen_cast", {:stereo_calibration_changed, _prefix}}
    end

    test "commit/3 whose reload does not answer puts the files back and has the unit reload them",
         %{tmp_dir: tmp_dir, prefix: prefix, config: config} do
      test = self()
      left_store = Path.join(store(tmp_dir), "#{prefix}_left.yaml")
      left_built_in = Path.join(tmp_dir, "built_in/#{prefix}_left.yaml")
      right_built_in = Path.join(tmp_dir, "built_in/#{prefix}_right.yaml")

      reload = fn paths ->
        send(test, {:reloaded, paths})
        if paths[:left_calibration_path] == left_store, do: exit({:timeout, :reload}), else: :ok
      end

      assert {:error, message} = Calibration.commit(config, distorted(), running(reload: reload))

      assert message =~ "timeout"
      refute File.exists?(left_store)
      assert_received {:reloaded, [left_calibration_path: ^left_store, right_calibration_path: _]}

      assert_received {:reloaded,
                       [
                         left_calibration_path: ^left_built_in,
                         right_calibration_path: ^right_built_in
                       ]}

      refute_received {:"$gen_cast", {:stereo_calibration_changed, _prefix}}
    end

    test "in_use/1 says why a stored file it cannot parse gives no calibration",
         %{tmp_dir: tmp_dir, prefix: prefix, config: config} do
      :ok = Calibration.commit(config, distorted(), reloading(:ok))
      left_store = Path.join(store(tmp_dir), "#{prefix}_left.yaml")

      emptied =
        left_store
        |> File.read!()
        |> String.replace(~r/projection_matrix:.*\]/s, "projection_matrix:\n  data: []")

      File.write!(left_store, emptied)

      assert {:ok, in_use} = Calibration.in_use(config)

      assert in_use.error =~ "projection matrix"
      assert in_use.left.calibration == nil
      assert in_use.right.calibration == distorted().right
      assert in_use.baseline_m == nil
      assert in_use.can_reset
    end

    test "reset/2 removes the stored calibration, reloads the built-in one and tells the change",
         %{tmp_dir: tmp_dir, prefix: prefix, config: config} do
      :ok = Calibration.commit(config, distorted(), reloading(:ok))
      assert_received {:"$gen_cast", {:stereo_calibration_changed, ^prefix}}
      left_built_in = Path.join(tmp_dir, "built_in/#{prefix}_left.yaml")
      right_built_in = Path.join(tmp_dir, "built_in/#{prefix}_right.yaml")

      assert :ok = Calibration.reset(config, reloading(:ok))

      refute File.exists?(Path.join(store(tmp_dir), "#{prefix}_left.yaml"))
      refute File.exists?(Path.join(store(tmp_dir), "#{prefix}_right.yaml"))

      assert_received {:reloaded,
                       [
                         left_calibration_path: ^left_built_in,
                         right_calibration_path: ^right_built_in
                       ]}

      assert_received {:"$gen_cast", {:stereo_calibration_changed, ^prefix}}

      assert {:ok, %{source: :built_in, stored_at: nil, can_reset: false} = in_use} =
               Calibration.in_use(config)

      assert in_use.left.path == left_built_in
      assert_in_delta in_use.baseline_m, 0.1, 1.0e-9
    end

    test "reset/2 is refused with nothing stored", %{config: config} do
      assert {:error, _message} = Calibration.reset(config, reloading(:ok))
      refute_received {:reloaded, _paths}
    end

    test "reset/2 is refused without a built-in calibration to go back to",
         %{tmp_dir: tmp_dir, prefix: prefix, config: config} do
      :ok = Calibration.commit(config, distorted(), reloading(:ok))
      File.rm!(Path.join(tmp_dir, "built_in/#{prefix}_right.yaml"))

      assert {:ok, %{source: :stored, can_reset: false}} = Calibration.in_use(config)
      assert {:error, _message} = Calibration.reset(config, reloading(:ok))
      assert File.exists?(Path.join(store(tmp_dir), "#{prefix}_left.yaml"))
    end

    test "a side stored alone can be reset to the built-in calibration",
         %{tmp_dir: tmp_dir, prefix: prefix, config: config} do
      stored = Path.join(store(tmp_dir), "#{prefix}_left.yaml")
      File.mkdir_p!(store(tmp_dir))

      File.write!(
        stored,
        VisionCore.Ros2.CameraCalibration.to_yaml(distorted().left, "#{prefix}_left")
      )

      assert {:ok, %{source: :built_in, stored_at: nil, can_reset: true}} =
               Calibration.in_use(config)

      assert :ok = Calibration.reset(config, reloading(:ok))
      refute File.exists?(Path.join(store(tmp_dir), "#{prefix}_left.yaml"))
      assert {:ok, %{can_reset: false}} = Calibration.in_use(config)
    end
  end

  describe "commit_side/4 with a store" do
    setup %{tmp_dir: tmp_dir, test: test} do
      prefix = prefix(test)
      install_built_in(tmp_dir, prefix)
      subscribe(prefix)

      %{
        prefix: prefix,
        config: tmp_dir |> config(prefix) |> with_store(tmp_dir),
        left_store: Path.join(store(tmp_dir), "#{prefix}_left.yaml"),
        right_store: Path.join(store(tmp_dir), "#{prefix}_right.yaml")
      }
    end

    test "stores a first side without having the unit take it, and tells the change", context do
      assert :ok =
               Calibration.commit_side(context.config, :left, distorted().left, reloading(:ok))

      assert File.read!(context.left_store) =~ "camera_name: #{context.prefix}_left"
      refute File.exists?(context.right_store)
      refute_received {:reloaded, _paths}
      assert_received {:"$gen_cast", {:stereo_calibration_changed, _prefix}}
      assert {:ok, %{source: :built_in}} = Calibration.in_use(context.config)
    end

    test "has the unit reload from the store once the other side is stored", context do
      %{left_store: left_store, right_store: right_store} = context
      :ok = Calibration.commit_side(context.config, :left, distorted().left, reloading(:ok))

      assert :ok =
               Calibration.commit_side(context.config, :right, distorted().right, reloading(:ok))

      assert_received {:reloaded,
                       [left_calibration_path: ^left_store, right_calibration_path: ^right_store]}

      assert {:ok, %{source: :stored}} = Calibration.in_use(context.config)
    end

    test "puts back what the side held when the unit refuses, the other side kept", context do
      :ok = Calibration.commit(context.config, distorted(), reloading(:ok))
      stored = {File.read!(context.left_store), File.read!(context.right_store)}
      built_in = CameraCalibration.load!(Path.join(@fixtures, "stereo_right.yaml"))

      assert {:error, message} =
               Calibration.commit_side(
                 context.config,
                 :right,
                 built_in,
                 reloading({:error, :bad_calibration})
               )

      assert message =~ "bad_calibration"
      assert {File.read!(context.left_store), File.read!(context.right_store)} == stored
    end

    test "leaves the file as it was when the new one cannot be written", context do
      File.mkdir_p!(store(context.tmp_dir))
      File.write!(context.left_store, "stored left")
      File.mkdir_p!(context.left_store <> ".tmp")

      assert {:error, message} =
               Calibration.commit_side(context.config, :left, distorted().left, reloading(:ok))

      assert message =~ "write failed"
      assert File.read!(context.left_store) == "stored left"
      refute_received {:"$gen_cast", {:stereo_calibration_changed, _prefix}}
    end

    test "restarts a unit whose pipeline is not running once both sides are stored", context do
      test = self()

      restart = fn ->
        send(test, :restarted)
        {:ok, self()}
      end

      :ok = Calibration.commit_side(context.config, :left, distorted().left, stopped([]))
      refute_received :restarted

      assert :ok =
               Calibration.commit_side(
                 context.config,
                 :right,
                 distorted().right,
                 stopped(restart: restart)
               )

      assert_received :restarted
    end
  end

  test "commit_side/4 without a store writes the side's calibration path and reloads both",
       %{tmp_dir: tmp_dir, test: test} do
    prefix = prefix(test)
    install_built_in(tmp_dir, prefix)
    left = Path.join(tmp_dir, "built_in/#{prefix}_left.yaml")
    right = Path.join(tmp_dir, "built_in/#{prefix}_right.yaml")

    assert :ok =
             Calibration.commit_side(
               config(tmp_dir, prefix),
               :left,
               distorted().left,
               reloading(:ok)
             )

    assert File.read!(left) =~ "camera_name: #{prefix}_left"
    assert_received {:reloaded, [left_calibration_path: ^left, right_calibration_path: ^right]}
  end

  describe "without a store" do
    setup %{tmp_dir: tmp_dir, test: test} do
      prefix = prefix(test)
      install_built_in(tmp_dir, prefix)
      subscribe(prefix)
      %{prefix: prefix, config: config(tmp_dir, prefix)}
    end

    test "commit/3 writes the calibration paths, and reset/2 is refused",
         %{tmp_dir: tmp_dir, prefix: prefix, config: config} do
      left = Path.join(tmp_dir, "built_in/#{prefix}_left.yaml")
      right = Path.join(tmp_dir, "built_in/#{prefix}_right.yaml")

      assert :ok = Calibration.commit(config, distorted(), reloading(:ok))

      assert File.read!(left) =~ "camera_name: #{prefix}_left"
      assert_received {:reloaded, [left_calibration_path: ^left, right_calibration_path: ^right]}
      assert_received {:"$gen_cast", {:stereo_calibration_changed, ^prefix}}

      assert {:ok, %{source: :built_in, can_reset: false, stored_at: nil}} =
               Calibration.in_use(config)

      assert {:error, _message} = Calibration.reset(config, reloading(:ok))
      refute_received {:reloaded, _paths}
    end
  end

  describe "a unit whose pipeline is not running" do
    setup %{tmp_dir: tmp_dir, test: test} do
      prefix = prefix(test)
      subscribe(prefix)

      %{
        prefix: prefix,
        config: config(tmp_dir, prefix),
        left: Path.join(tmp_dir, "built_in/#{prefix}_left.yaml"),
        right: Path.join(tmp_dir, "built_in/#{prefix}_right.yaml")
      }
    end

    # Records each restart in the test's mailbox, with whether `path` is there, and answers `answer`.
    defp restart(path, answer) do
      test = self()

      fn ->
        send(test, {:restarted, File.exists?(path)})
        answer
      end
    end

    test "commit/3 writes the files and restarts the stereo unit instead of reloading it",
         %{prefix: prefix, config: config, left: left, right: right} do
      assert :ok =
               Calibration.commit(
                 config,
                 distorted(),
                 stopped(reload: reload(:ok), restart: restart(left, {:ok, self()}))
               )

      assert File.read!(left) =~ "camera_name: #{prefix}_left"
      assert File.read!(right) =~ "camera_name: #{prefix}_right"
      assert_received {:restarted, true}
      refute_received {:restarted, _left?}
      refute_received {:reloaded, _paths}
      assert_received {:"$gen_cast", {:stereo_calibration_changed, ^prefix}}
    end

    for {refusal, answer} <- [
          {"refuses to restart it", quote(do: {:error, :running})},
          {"does not start it", quote(do: {:ok, :undefined})}
        ] do
      test "commit/3 removes the files when the supervisor #{refusal}, then restarts the unit without them",
           %{config: config, left: left, right: right} do
        assert {:error, message} =
                 Calibration.commit(
                   config,
                   distorted(),
                   stopped(restart: restart(left, unquote(answer)))
                 )

        assert message == "the stereo unit did not start with this calibration; the log says why"
        refute File.exists?(left)
        refute File.exists?(right)
        assert_received {:restarted, true}
        assert_received {:restarted, false}
        refute_received {:"$gen_cast", {:stereo_calibration_changed, _prefix}}
      end
    end

    test "commit/3 removes the files when the restart raises",
         %{config: config, left: left, right: right} do
      assert {:error, _message} =
               Calibration.commit(
                 config,
                 distorted(),
                 stopped(restart: fn -> raise "no unit" end)
               )

      refute File.exists?(left)
      refute File.exists?(right)
    end

    test "commit/3 removes the files when forgetting the row offset raises",
         %{tmp_dir: tmp_dir, prefix: prefix, left: left, right: right} do
      # A stage that is no module makes the forget raise.
      config = config(tmp_dir, prefix, stages: [:not_a_module])

      assert {:error, message} =
               Calibration.commit(
                 config,
                 distorted(),
                 stopped(restart: restart(left, {:ok, self()}))
               )

      assert message == "the stereo unit did not start with this calibration; the log says why"
      refute File.exists?(left)
      refute File.exists?(right)
      refute_received {:restarted, _left?}
    end

    test "reset/2 restarts the unit on the built-in calibration",
         %{tmp_dir: tmp_dir, prefix: prefix, config: config, left: left} do
      install_built_in(tmp_dir, prefix)
      config = with_store(config, tmp_dir)
      :ok = Calibration.commit(config, distorted(), stopped(restart: fn -> {:ok, self()} end))

      assert :ok =
               Calibration.reset(
                 config,
                 stopped(reload: reload(:ok), restart: restart(left, {:ok, self()}))
               )

      assert_received {:restarted, true}
      refute_received {:reloaded, _paths}
      refute File.exists?(Path.join(store(tmp_dir), "#{prefix}_left.yaml"))
    end
  end

  test "commit/3 leaves the files as they were when the second cannot be written",
       %{tmp_dir: tmp_dir, test: test} do
    prefix = prefix(test)
    subscribe(prefix)
    left = Path.join(tmp_dir, "left/stereo_left.yaml")
    File.mkdir_p!(Path.dirname(left))
    File.write!(left, "left in use")
    read_only = Path.join(tmp_dir, "read_only")
    File.mkdir_p!(read_only)
    File.chmod!(read_only, 0o555)
    on_exit(fn -> File.chmod(read_only, 0o755) end)

    config =
      config(tmp_dir, prefix,
        left: [calibration_path: left],
        right: [calibration_path: Path.join(read_only, "stereo_right.yaml")]
      )

    assert {:error, message} = Calibration.commit(config, distorted(), reloading(:ok))

    assert message =~ "write failed"
    assert File.read!(left) == "left in use"
    assert File.ls!(Path.dirname(left)) == ["stereo_left.yaml"]
    refute_received {:reloaded, _paths}
    refute_received {:"$gen_cast", {:stereo_calibration_changed, _prefix}}
  end

  test "in_use/1 says :none without any calibration file", %{tmp_dir: tmp_dir, test: test} do
    prefix = prefix(test)

    assert {:ok, in_use} = Calibration.in_use(tmp_dir |> config(prefix) |> with_store(tmp_dir))

    assert %{source: :none, stored_at: nil, can_reset: false, baseline_m: nil, error: nil} =
             in_use

    assert %{calibration: nil, yaml: nil} = in_use.left
    assert %{calibration: nil, yaml: nil} = in_use.right
  end

  test "in_use/1 answers why without a stereo unit" do
    assert {:error, _reason} = Calibration.in_use(%VisionCore.Config{})
  end
end
