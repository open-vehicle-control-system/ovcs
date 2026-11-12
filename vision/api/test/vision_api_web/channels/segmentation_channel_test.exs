defmodule VisionApiWeb.SegmentationChannelTest do
  use VisionApiWeb.ChannelCase, async: false

  alias Phoenix.Socket.Message
  alias VisionCore.Camera.Frame
  alias VisionCore.Pipelines
  alias VisionCore.Segmentation.Live

  @moduletag :capture_log

  # A camera of its own that captures nothing.
  defmodule NamedCamera do
    def name_for(label), do: Module.concat(__MODULE__, label)
    def child_spec(opts), do: %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}}
    def start_link(_opts), do: {:ok, spawn_link(fn -> Process.sleep(:infinity) end)}
  end

  defp join(topic) do
    VisionApiWeb.DashboardSocket
    |> socket()
    |> subscribe_and_join(VisionApiWeb.SegmentationChannel, topic)
  end

  defp segmenter(name, options) do
    {:segmenter,
     Keyword.merge(
       [
         name: name,
         backend: VisionCore.Segmentation.Backend.Stub,
         source: {:camera, :hq},
         max_hz: 1_000
       ],
       options
     )}
  end

  defp start_unit(segmenter_options \\ [], others \\ []) do
    VisionApiWeb.TestUnit.start(%VisionCore.Config{
      components:
        [
          {:camera, name: :hq, driver: NamedCamera},
          {:detector,
           name: :hq_people, backend: VisionCore.Detection.Backend.Stub, source: {:camera, :hq}},
          segmenter(:road, segmenter_options),
          # Left down: a segmentation pipeline needs a camera.
          {:segmenter, name: :sourceless, backend: VisionCore.Segmentation.Backend.Stub}
        ] ++ others
    })
  end

  # As the pipeline publishes it: a 4 × 2 grid over the bottom band of a 1014 × 760 frame.
  defp result(name, data) do
    frame = %Frame{label: "hq", width: 1014, height: 760, capture_ns: 0}
    labels = %{width: 4, height: 2, data: data, band: {0, 253, 1014, 507}}
    {:segmentation, name, frame, labels, nil}
  end

  defp publish(name \\ :road, data),
    do: GenServer.cast(Pipelines.server(Live, name), result(name, data))

  defp grid(<<_header::binary-16, data::binary>>), do: data

  test "pushes each result as its frame's size, its band and its label grid, little-endian" do
    start_unit()
    {:ok, _reply, _socket} = join("segmentation:road")

    publish(<<10, 10, 10, 10, 0, 0, 1, 13>>)

    assert_push "segmentation", {:binary, payload}

    assert payload ==
             <<1014::little-16, 760::little-16, 0::little-16, 253::little-16, 1014::little-16,
               507::little-16, 4::little-16, 2::little-16, 10, 10, 10, 10, 0, 0, 1, 13>>
  end

  test "pushes the pipeline's class names and its road classes before its first grid" do
    start_unit(road_classes: ["road", "sidewalk"])
    {:ok, _reply, _socket} = join("segmentation:road")
    publish(<<0, 0, 0, 0, 0, 0, 0, 0>>)

    assert_receive %Message{event: first, payload: classes}
    assert first == "classes"
    assert %{labels: labels, roadClasses: ["road", "sidewalk"]} = classes
    assert labels == VisionCore.Segmentation.labels()
    assert_push "segmentation", {:binary, _payload}
  end

  test "pushes the classes again to a client rejoining after the pipeline's Live restarts" do
    Process.flag(:trap_exit, true)
    start_unit(road_classes: ["road", "terrain"])
    {:ok, _reply, socket} = join("segmentation:road")
    assert_push "classes", _classes
    monitor = Process.monitor(socket.channel_pid)
    live = GenServer.whereis(Pipelines.server(Live, :road))

    Process.exit(live, :kill)
    assert_receive {:DOWN, ^monitor, :process, _pid, :source_restarted}, 500
    :ok = wait_for_restart(Pipelines.server(Live, :road), live)

    {:ok, _reply, _socket} = join("segmentation:road")
    assert_push "classes", %{roadClasses: ["road", "terrain"]}
  end

  test "pushes the next grid only once the client acks, the newest replacing one not sent" do
    start_unit()
    {:ok, _reply, socket} = join("segmentation:road")

    publish(<<1, 1, 1, 1, 1, 1, 1, 1>>)
    assert_push "segmentation", {:binary, first}
    assert grid(first) == <<1, 1, 1, 1, 1, 1, 1, 1>>

    publish(<<2, 2, 2, 2, 2, 2, 2, 2>>)
    publish(<<3, 3, 3, 3, 3, 3, 3, 3>>)
    refute_push "segmentation", _payload, 200

    push(socket, "ack", %{})
    assert_push "segmentation", {:binary, newest}, 500
    assert grid(newest) == <<3, 3, 3, 3, 3, 3, 3, 3>>
    refute_push "segmentation", _payload, 200

    # Nothing is held: the ack leaves the client due the next grid at once.
    push(socket, "ack", %{})
    publish(<<4, 4, 4, 4, 4, 4, 4, 4>>)
    assert_push "segmentation", {:binary, next}, 500
    assert grid(next) == <<4, 4, 4, 4, 4, 4, 4, 4>>
  end

  test "pushes at most max_hz results a second, the latest held until its turn" do
    start_unit(max_hz: 2)
    {:ok, _reply, socket} = join("segmentation:road")

    publish(<<0, 0, 0, 0, 0, 0, 0, 0>>)
    publish(<<1, 1, 1, 1, 1, 1, 1, 1>>)
    publish(<<2, 2, 2, 2, 2, 2, 2, 2>>)

    assert_push "segmentation", {:binary, <<_header::binary-16, 0, _rest::binary>>}
    push(socket, "ack", %{})
    refute_push "segmentation", _payload, 200
    assert_push "segmentation", {:binary, <<_header::binary-16, 2, _rest::binary>>}, 2_000
    push(socket, "ack", %{})
    refute_push "segmentation", _payload, 300
  end

  test "pushes each of two pipelines' grids and classes on its own channel only" do
    start_unit([road_classes: ["road"]], [segmenter(:lanes, road_classes: ["sidewalk"])])
    {:ok, _reply, road} = join("segmentation:road")
    {:ok, _reply, lanes} = join("segmentation:lanes")

    publish(:road, <<0, 0, 0, 0, 0, 0, 0, 0>>)
    publish(:lanes, <<1, 1, 1, 1, 1, 1, 1, 1>>)

    road_topic = road.topic
    lanes_topic = lanes.topic

    assert_receive %Message{
      topic: ^road_topic,
      event: "classes",
      payload: %{roadClasses: ["road"]}
    }

    assert_receive %Message{
      topic: ^lanes_topic,
      event: "classes",
      payload: %{roadClasses: ["sidewalk"]}
    }

    assert_receive %Message{
      topic: ^road_topic,
      event: "segmentation",
      payload: {:binary, road_grid}
    }

    assert_receive %Message{
      topic: ^lanes_topic,
      event: "segmentation",
      payload: {:binary, lanes_grid}
    }

    assert grid(road_grid) == <<0, 0, 0, 0, 0, 0, 0, 0>>
    assert grid(lanes_grid) == <<1, 1, 1, 1, 1, 1, 1, 1>>
    refute_receive %Message{event: "segmentation"}, 200
  end

  describe "refuses as unavailable" do
    setup do
      start_unit()
    end

    test "a name that is not an existing atom, without creating one" do
      name = "no_such_pipeline_" <> Integer.to_string(System.unique_integer([:positive]))

      assert {:error, %{reason: "unavailable"}} = join("segmentation:" <> name)
      assert_raise ArgumentError, fn -> String.to_existing_atom(name) end
    end

    test "an existing atom that names no configured pipeline, even while its Live runs" do
      start_supervised!({Live, name: :unlisted})

      assert {:error, %{reason: "unavailable"}} = join("segmentation:unlisted")
    end

    test "a detection pipeline's name" do
      assert {:error, %{reason: "unavailable"}} = join("segmentation:hq_people")
    end

    test "a configured pipeline that does not run" do
      assert {:error, %{reason: "unavailable"}} = join("segmentation:sourceless")
    end
  end

  test "refuses a pipeline on a unit that runs none as unavailable" do
    assert {:error, %{reason: "unavailable"}} = join("segmentation:road")
  end

  # Polls until `server` runs under a pid other than `old_pid`, for at most a second.
  defp wait_for_restart(server, old_pid, tries \\ 100) do
    case GenServer.whereis(server) do
      pid when is_pid(pid) and pid != old_pid ->
        :ok

      _down when tries > 0 ->
        receive after: (10 -> wait_for_restart(server, old_pid, tries - 1))

      _down ->
        flunk("#{inspect(server)} did not restart")
    end
  end
end
