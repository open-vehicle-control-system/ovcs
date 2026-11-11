defmodule VisionCore.Camera.UnitTest do
  use ExUnit.Case, async: true

  alias VisionCore.Camera.{GStreamer, Unit, V4L2Single}

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

  test "each camera's frames are an output, under its driver's key" do
    config = config([{:camera, name: :hq, driver: V4L2Single, csiphy: 2}])

    assert Unit.outputs(config) == [
             {{:camera_frame, :hq}, {:camera_frame, V4L2Single.name_for("hq")}}
           ]
  end

  test "a configuration without a camera has none, and a driver that is no camera gives none" do
    assert Unit.cameras(config([{:stereo, driver: GStreamer, left: [], right: []}])) == []
    assert Unit.outputs(config([])) == []
    assert Unit.cameras(config([{:camera, name: :hq, driver: Enum}])) == []
  end
end
