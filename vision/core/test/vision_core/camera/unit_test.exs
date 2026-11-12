defmodule VisionCore.Camera.UnitTest do
  use ExUnit.Case, async: true

  alias VisionCore.Camera.{GStreamer, Output, Unit, V4L2Single}

  # Hands the test the options it is started with.
  defmodule Driver do
    def name_for(label), do: Module.concat(__MODULE__, label)

    def child_spec(opts), do: %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}}

    def start_link(opts) do
      send(Keyword.fetch!(opts, :test), {:driver_started, opts})
      {:ok, spawn_link(fn -> Process.sleep(:infinity) end)}
    end
  end

  defp config(components), do: %VisionCore.Config{components: components}

  test "starts its driver with the camera's options and its name's text as the label" do
    start_supervised!({Unit, name: :usb, driver: Driver, device: "/dev/video0", test: self()})

    assert_receive {:driver_started, opts}
    assert opts[:label] == "usb"
    assert opts[:name] == :usb
    assert opts[:device] == "/dev/video0"
    refute Keyword.has_key?(opts, :driver)
  end

  test "its driver is given the optical frame \"<name>_optical\" unless the camera sets one" do
    start_supervised!({Unit, name: :usb, driver: Driver, test: self()}, id: :default)
    assert_receive {:driver_started, opts}
    assert opts[:frame_id] == "usb_optical"

    start_supervised!({Unit, name: :other, driver: Driver, frame_id: "rig", test: self()},
      id: :set
    )

    assert_receive {:driver_started, opts}
    assert opts[:frame_id] == "rig"
  end

  test "its driver is not given the camera's calibration, pose or calibration store" do
    start_supervised!(
      {Unit,
       name: :usb,
       driver: Driver,
       calibration: "usb.yaml",
       pose: "usb_pose.yaml",
       calibration_store_dir: "/data",
       test: self()}
    )

    assert_receive {:driver_started, opts}
    refute Keyword.has_key?(opts, :calibration)
    refute Keyword.has_key?(opts, :pose)
    refute Keyword.has_key?(opts, :calibration_store_dir)
  end

  test "each camera of the configuration, in its order, with its driver and registered name" do
    config =
      config([
        {:stereo, driver: GStreamer, left: [], right: []},
        {:camera, name: :hq, driver: V4L2Single, csiphy: 2},
        :detector,
        {:camera, name: :usb, driver: GStreamer, device: "/dev/video0"}
      ])

    assert Unit.cameras(config) == [
             {:hq, V4L2Single, V4L2Single.name_for("hq")},
             {:usb, GStreamer, GStreamer.name_for("usb")}
           ]
  end

  test "each camera's frames are an output, under its driver's key for its default output" do
    config =
      config([
        {:camera, name: :hq, driver: V4L2Single, csiphy: 2},
        {:camera, name: :usb, driver: GStreamer, device: "/dev/video0"}
      ])

    assert Unit.outputs(config) == [
             {{:camera_frame, :hq}, {:camera_frame, V4L2Single.name_for("hq"), :full}},
             {{:camera_frame, :usb}, {:camera_frame, GStreamer.name_for("usb")}}
           ]
  end

  describe "output_key/3" do
    @outputs [
      view: [resolution: {2028, 1520}, processor: :cpu],
      inference: [resolution: {1014, 760}, from: :view]
    ]

    test "gives each named output its own key, the first the default" do
      config = config([{:camera, name: :hq, driver: V4L2Single, csiphy: 2, outputs: @outputs}])
      server = V4L2Single.name_for("hq")

      assert Unit.output_key(config, :hq, nil) == {:camera_frame, server, :view}
      assert Unit.output_key(config, :hq, :view) == {:camera_frame, server, :view}
      assert Unit.output_key(config, :hq, :inference) == {:camera_frame, server, :inference}
      assert Unit.outputs(config) == [{{:camera_frame, :hq}, {:camera_frame, server, :view}}]
    end

    test "is nil for an output or a camera the configuration does not have" do
      config =
        config([
          {:camera, name: :hq, driver: V4L2Single, csiphy: 2, outputs: @outputs},
          {:camera, name: :usb, driver: GStreamer, device: "/dev/video0"}
        ])

      assert Unit.output_key(config, :hq, :preview) == nil
      assert Unit.output_key(config, :front, nil) == nil
      assert Unit.output_key(config, :usb, :view) == nil
      assert Unit.output_key(config, :usb, nil) == {:camera_frame, GStreamer.name_for("usb")}
    end
  end

  describe "init/1" do
    test "refuses outputs the camera's driver cannot make, naming the camera" do
      for {opts, message} <- [
            {[outputs: [view: [resolution: {2028, 1520}, processor: :isp]]],
             "camera hq: output view: its processor :isp is not one this driver has (:cpu)"},
            {[outputs: [view: [resolution: {640, 480}, processor: :cpu]]],
             "camera hq: output view: its processor :cpu cannot make 640x480; " <>
               "it makes 2028x1520 or 1014x760"},
            {[
               outputs: [
                 view: [resolution: {2028, 1520}, processor: :cpu],
                 inference: [resolution: {1000, 760}, from: :view]
               ]
             ], "camera hq: output inference: 1000x760 is no whole fraction of view's 2028x1520"},
            {[outputs: [view: [resolution: {2028, 1520}, from: :inference]]],
             "camera hq: output view: its :from, :inference, is no output of the camera"},
            {[output: :quarter], "camera hq: :output is :full or :half, got :quarter"}
          ] do
        assert_raise ArgumentError, message, fn ->
          Unit.init([name: :hq, driver: V4L2Single, csiphy: 2] ++ opts)
        end
      end
    end

    test "refuses outputs on a driver without named outputs" do
      assert_raise ArgumentError,
                   "camera usb: its driver, VisionCore.Camera.GStreamer, has no outputs",
                   fn ->
                     Unit.init(
                       name: :usb,
                       driver: GStreamer,
                       outputs: [view: [resolution: {640, 480}, processor: :cpu]]
                     )
                   end
    end
  end

  test "a configuration without a camera has none, and a driver that is no camera gives none" do
    assert Unit.cameras(config([{:stereo, driver: GStreamer, left: [], right: []}])) == []
    assert Unit.outputs(config([])) == []
    assert Unit.cameras(config([{:camera, name: :hq, driver: Enum}])) == []
  end

  describe "settings/1" do
    test "each camera's frame id, calibration, pose and registered name" do
      config =
        config([
          {:camera,
           name: :hq,
           driver: V4L2Single,
           calibration: "hq.yaml",
           pose: "hq_pose.yaml",
           output: :half},
          {:camera, name: :usb, driver: GStreamer, frame_id: "usb_link"}
        ])

      assert Unit.settings(config) == [
               %{
                 name: :hq,
                 server: V4L2Single.name_for("hq"),
                 frame_id: "hq_optical",
                 calibration_path: "hq.yaml",
                 calibration_store_path: nil,
                 pose_path: "hq_pose.yaml",
                 outputs: [
                   %Output{name: :half, index: 0, width: 1014, height: 760, processor: :cpu}
                 ]
               },
               %{
                 name: :usb,
                 server: GStreamer.name_for("usb"),
                 frame_id: "usb_link",
                 calibration_path: nil,
                 calibration_store_path: nil,
                 pose_path: nil,
                 outputs: []
               }
             ]
    end

    @tag :tmp_dir
    test "a calibration stored as camera_<name>.yaml takes precedence over :calibration",
         %{tmp_dir: tmp_dir} do
      config =
        config([
          {:camera,
           name: :hq, driver: V4L2Single, calibration: "hq.yaml", calibration_store_dir: tmp_dir}
        ])

      stored = Path.join(tmp_dir, "camera_hq.yaml")

      assert [%{calibration_path: "hq.yaml", calibration_store_path: ^stored}] =
               Unit.settings(config)

      File.write!(stored, "image_width: 8\n")

      assert [%{calibration_path: ^stored, calibration_store_path: ^stored}] =
               Unit.settings(config)
    end
  end
end
