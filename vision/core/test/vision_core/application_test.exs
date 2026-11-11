defmodule VisionCore.ApplicationTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias VisionCore.Camera.{Frame, LibCamera}
  alias VisionCore.Parameters.SavedValue
  alias VisionCore.Repo

  @moduletag :tmp_dir
  @moduletag :capture_log
  @calibration_dir Path.expand("../support/calibration", __DIR__)

  defmodule Composer do
    @behaviour VisionCore.Composer

    @impl VisionCore.Composer
    def config(_arm), do: Application.fetch_env!(:vision_core, :test_config)
  end

  # The pipeline's Storage owns VisionCore.Repo here, on an empty store, and the pipeline starts
  # its own VisionCore.Outputs; test_helper's are back after.
  setup do
    Application.stop(:vision_core)
    Repo.delete_all(SavedValue)
    :ok = Supervisor.stop(Repo)
    :ok = Supervisor.stop(VisionCore.Outputs)

    on_exit(fn ->
      Application.stop(:vision_core)
      Application.delete_env(:vision_core, :vehicle)
      Application.delete_env(:vision_core, :test_config)
      Application.ensure_all_started(:vision_core)
      {:ok, pid} = Repo.start_link()
      Process.unlink(pid)
      {:ok, outputs} = VisionCore.Outputs.start_link()
      Process.unlink(outputs)
    end)
  end

  defp start_pipeline(config) do
    Application.put_env(:vision_core, :test_config, config)
    Application.put_env(:vision_core, :vehicle, Composer)
    {:ok, _apps} = Application.ensure_all_started(:vision_core)
  end

  defp child_ids(supervisor) do
    supervisor |> Supervisor.which_children() |> Enum.map(&elem(&1, 0))
  end

  defp child_pid(supervisor, id) do
    {_id, pid, _type, _modules} =
      supervisor |> Supervisor.which_children() |> List.keyfind(id, 0)

    pid
  end

  @ros2 [zenoh_endpoint_ip: "127.0.0.1"]
  @ros2_processes [
    Ros2Zenoh.Client,
    VisionCore.Ros2.Parameters,
    VisionCore.Ros2.Topics,
    VisionCore.Ros2.Clock
  ]

  test "without ros2:, no ROS 2 process starts and the unit runs" do
    start_pipeline(%VisionCore.Config{})

    ids = child_ids(VisionCore.Supervisor)
    for process <- @ros2_processes, do: refute(process in ids)
    assert Process.alive?(Process.whereis(VisionCore.Status))
    assert Process.alive?(Process.whereis(VisionCore.Exporters))
  end

  test "with ros2:, the ROS 2 link starts, and the ROS 2 exporter publishes the heartbeat through it" do
    start_pipeline(%VisionCore.Config{
      ros2: @ros2,
      exporters: [{VisionCore.Ros2.Exporter, heartbeat: [interval_ms: 50]}]
    })

    ids = child_ids(VisionCore.Supervisor)
    assert Ros2Zenoh.Client in ids
    assert VisionCore.Ros2.Parameters in ids
    assert VisionCore.Ros2.Topics in ids

    assert eventually(fn ->
             Enum.any?(VisionCore.Ros2.Topics.topics(), &(&1.name == "/ovcs_heartbeat"))
           end)
  end

  test "ros2: gives the Zenoh client its router, node name and domain" do
    start_pipeline(%VisionCore.Config{
      ros2: [zenoh_endpoint_ip: "127.0.0.2", node_name: "front_vision", domain_id: 7]
    })

    assert %{endpoint: "tcp/127.0.0.2:7447", node_name: "front_vision", domain_id: 7} =
             VisionCore.Ros2.Node.link()
  end

  test "boots with ros2: while the Zenoh router does not answer" do
    # TEST-NET-1, where nothing answers.
    start_pipeline(%VisionCore.Config{ros2: [zenoh_endpoint_ip: "192.0.2.1"]})

    assert Process.alive?(Process.whereis(VisionCore.Ros2.Parameters))
    assert Process.alive?(Process.whereis(VisionCore.Status))
    assert %{connected: false} = VisionCore.Ros2.Node.link()
  end

  test "a ros2: that is no keyword list, or without the router's address, fails the start saying so" do
    for {ros2, message} <- [
          {"192.0.2.1", "ros2: is a keyword list"},
          {[node_name: "front_vision"],
           "ros2: needs :zenoh_endpoint_ip, the Zenoh router's address"}
        ] do
      Application.put_env(:vision_core, :test_config, %VisionCore.Config{ros2: ros2})
      Application.put_env(:vision_core, :vehicle, Composer)

      assert {:error, {:vision_core, reason}} = Application.ensure_all_started(:vision_core)
      assert inspect(reason) =~ message
    end
  end

  test "a ROS 2 exporter without ros2: is not started, with the reason logged, and the unit runs" do
    log =
      capture_log(fn ->
        start_pipeline(%VisionCore.Config{
          exporters: [{VisionCore.Ros2.Exporter, heartbeat: []}]
        })
      end)

    assert log =~ "VisionCore.Ros2.Exporter not started"
    assert log =~ "ros2:"
    assert [%{id: "ros2", status: {:off, _detail}}] = VisionCore.Exporters.list()
    assert Process.alive?(Process.whereis(VisionCore.Status))
  end

  test "the exporters start after the components and their codec, before Status and the previews" do
    start_pipeline(%VisionCore.Config{
      ros2: @ros2,
      exporters: [{VisionCore.Ros2.Exporter, heartbeat: []}]
    })

    assert Enum.take(child_ids(VisionCore.Supervisor), 4) == [
             VisionCore.Preview,
             VisionCore.Status,
             VisionCore.Exporters,
             VisionCore.Jpeg.Export
           ]

    assert for(
             {id, _pid, :supervisor, _} <- Supervisor.which_children(VisionCore.Exporters),
             do: id
           ) == [:ros2]
  end

  test "a restart of Status or the previews leaves the exporters running" do
    start_pipeline(%VisionCore.Config{
      ros2: @ros2,
      exporters: [{VisionCore.Ros2.Exporter, heartbeat: []}]
    })

    exporters = Process.whereis(VisionCore.Exporters)

    for name <- [VisionCore.Status, VisionCore.Preview] do
      pid = Process.whereis(name)
      Process.exit(pid, :kill)
      wait_for_restart(name, pid)
    end

    assert Process.whereis(VisionCore.Exporters) == exporters
  end

  test "the core starts the parameter storage and registry, the outputs registry, then the ROS 2 link, before the Port servers" do
    start_pipeline(%VisionCore.Config{
      ros2: @ros2 ++ [simulator_clock: [acquire_timeout_ms: 10]]
    })

    ids = VisionCore.Supervisor |> child_ids() |> Enum.reverse()

    assert Enum.take(ids, 9) == [
             VisionCore.Parameters.Storage,
             VisionCore.Parameters,
             VisionCore.Outputs,
             Ros2Zenoh.Client,
             VisionCore.Ros2.Parameters,
             VisionCore.Ros2.Topics,
             VisionCore.Ros2.Clock,
             VisionCore.Jpeg,
             VisionCore.Stereo.Matcher
           ]
  end

  @tag :jpeg
  test "the previews encode JPEG on a codec of their own, not the pipeline's" do
    start_pipeline(%VisionCore.Config{})
    :ok = :sys.suspend(VisionCore.Jpeg)
    :ok = VisionCore.Preview.subscribe(:left)
    frame = %Frame{label: "left", width: 2, height: 2, capture_ns: 1, grey: <<0, 64, 128, 255>>}

    GenServer.cast(VisionCore.Preview, {:camera_frame, frame})

    assert_receive {:vision_preview, :left, <<0xFF, 0xD8, _rest::binary>>}, 2_000
    :ok = :sys.resume(VisionCore.Jpeg)
  end

  test "starts the Matcher with the stereo_match binary and thread count of the app env",
       %{tmp_dir: tmp_dir} do
    for key <- [:stereo_match_path, :stereo_match_threads] do
      value = Application.get_env(:vision_core, key)
      on_exit(fn -> Application.put_env(:vision_core, key, value) end)
    end

    # A stereo_match that writes down its arguments, then reads its requests without answering.
    arguments = Path.join(tmp_dir, "arguments")

    stereo_match =
      write_script(tmp_dir, "stereo_match", ~s(echo "$@" > #{arguments}\nexec cat > /dev/null))

    Application.put_env(:vision_core, :stereo_match_path, stereo_match)
    Application.put_env(:vision_core, :stereo_match_threads, 3)
    start_pipeline(%VisionCore.Config{})

    VisionCore.Stereo.Matcher.send_run(VisionCore.Stereo.Matcher, self(), 0, 0, [], [])

    assert eventually(fn -> File.read(arguments) == {:ok, "--threads 3\n"} end)
  end

  test "a Zenoh client restart keeps the unsaved changes" do
    start_pipeline(%VisionCore.Config{ros2: @ros2})
    declare_sample()
    assert {:ok, %{state: :unsaved}} = VisionCore.Parameters.set("test.sample.value", 5)

    preview = Process.whereis(VisionCore.Preview)
    Process.exit(Process.whereis(Ros2Zenoh.Client), :kill)
    wait_for_restart(VisionCore.Preview, preview)

    assert {:ok, %{value: 5, state: :unsaved}} = VisionCore.Parameters.get("test.sample.value")
  end

  test "the pipeline starts on an empty store with its own Repo" do
    start_pipeline(%VisionCore.Config{})

    assert is_pid(child_pid(VisionCore.Supervisor, VisionCore.Parameters.Storage))
    declare_sample()
    assert {:ok, %{value: 1, saved: nil}} = VisionCore.Parameters.get("test.sample.value")
  end

  test "the config's preview options reach the preview" do
    start_pipeline(%VisionCore.Config{preview: [max_hz: 4, depth_range_m: 12]})

    assert VisionCore.Preview.options() == %{max_hz: 4, depth_range_m: 12.0}
  end

  test "the vision core starts with its parameters when the database cannot open" do
    repo_config = Application.get_env(:vision_core, Repo)
    on_exit(fn -> Application.put_env(:vision_core, Repo, repo_config) end)

    Application.put_env(
      :vision_core,
      Repo,
      Keyword.put(repo_config, :database, "/nonexistent/dir/vision.db")
    )

    capture_log(fn ->
      start_pipeline(%VisionCore.Config{})
    end)

    assert Process.alive?(Process.whereis(VisionCore.Parameters))
    assert Process.alive?(Process.whereis(VisionCore.Preview))
    declare_sample()
    assert {:ok, _parameter} = VisionCore.Parameters.set("test.sample.value", 5)
    assert {{:error, _reason}, _log} = with_log(fn -> VisionCore.Parameters.save() end)
  end

  test "settings are the config the pipeline started with" do
    start_pipeline(%VisionCore.Config{
      ros2: @ros2,
      exporters: [{VisionCore.Ros2.Exporter, heartbeat: [interval_ms: 500]}]
    })

    Application.put_env(:vision_core, :test_config, %VisionCore.Config{
      ros2: [zenoh_endpoint_ip: "10.0.0.9"]
    })

    assert %{
             "ros2" => %{"zenoh_endpoint_ip" => "127.0.0.1"},
             "exporters" => [
               %{
                 "module" => "VisionCore.Ros2.Exporter",
                 "options" => %{"heartbeat" => %{"interval_ms" => 500}}
               }
             ]
           } = VisionCore.settings()

    Application.stop(:vision_core)
    assert VisionCore.settings() == %{}
  end

  test "a detector that cannot start leaves the unit running without it, the reason logged" do
    log = capture_log(fn -> start_pipeline(%VisionCore.Config{components: [:hailo_detector]}) end)

    assert log =~ "VisionCore.Detection.Supervisor failed to start, detection down"
    refute Process.whereis(VisionCore.Detection.Supervisor)
    assert Process.alive?(Process.whereis(VisionCore.Status))
    assert Process.alive?(Process.whereis(VisionCore.Preview))
  end

  test "a named detector that cannot start leaves the other detectors running" do
    log =
      capture_log(fn ->
        start_pipeline(%VisionCore.Config{
          components: [
            {:detector, backend: VisionCore.Detection.Backend.Stub},
            {:hailo_detector, name: :road}
          ]
        })
      end)

    assert log =~ "VisionCore.Detection.Supervisor.Road failed to start, road down"
    refute Process.whereis(VisionCore.Detection.Supervisor.Road)
    assert Process.alive?(Process.whereis(VisionCore.Detection.Supervisor))
    assert Process.alive?(Process.whereis(VisionCore.Detection.Pipeline))
  end

  test "two detectors of one name fail the start, naming it" do
    for {components, name} <- [
          {[{:detector, backend: VisionCore.Detection.Backend.Stub}, :hailo_detector],
           ":detection"},
          {[{:detector, name: :road}, {:qnn_detector, name: :road}], ":road"}
        ] do
      Application.put_env(:vision_core, :test_config, %VisionCore.Config{components: components})
      Application.put_env(:vision_core, :vehicle, Composer)

      assert {:error, {:vision_core, reason}} = Application.ensure_all_started(:vision_core)
      assert inspect(reason) =~ "two detectors are named #{name}"
    end
  end

  test "the pipeline keeps running with no Zenoh router" do
    start_pipeline(%VisionCore.Config{
      ros2: @ros2,
      exporters: [{VisionCore.Ros2.Exporter, heartbeat: []}]
    })

    Process.sleep(2_000)

    assert Process.whereis(VisionCore.Supervisor) |> Process.alive?()
    assert Process.whereis(Ros2Zenoh.Client) |> Process.alive?()
  end

  # The first start of a 64x48 pipeline compiles the Nx stages with EXLA,
  # which takes longer than the cameras below live; later starts reuse it.
  setup_all do
    compile_pipeline()
    :ok
  end

  defp compile_pipeline do
    {:ok, pipeline} =
      VisionCore.Stereo.Pipeline.start_link(
        name: :application_test_compile,
        left_calibration_path: Path.join(@calibration_dir, "stereo_left.yaml"),
        right_calibration_path: Path.join(@calibration_dir, "stereo_right.yaml"),
        width: 64,
        height: 48,
        defn_options: Application.fetch_env!(:vision_core, :nx_defn_options)
      )

    GenServer.stop(pipeline)
  end

  # A 64x48 frame as camera_capture writes it, taken at the kernel's time 0.
  defp write_frame(tmp_dir) do
    jpeg = Evision.imencode(".jpg", Evision.Mat.zeros({48, 64}, :u8))
    frame = <<1, 64::little-16, 48::little-16, 0::little-64, byte_size(jpeg)::little-32>> <> jpeg
    frame_path = Path.join(tmp_dir, "frame.bin")
    File.write!(frame_path, <<byte_size(frame)::big-32>> <> frame)
    frame_path
  end

  defp stereo_component(left_executable, right_executable, side_options \\ []) do
    {:stereo,
     driver: LibCamera,
     width: 64,
     height: 48,
     fps: 5,
     left:
       [
         camera_id: 0,
         executable: left_executable,
         calibration_path: Path.join(@calibration_dir, "stereo_left.yaml")
       ] ++ side_options,
     right:
       [
         camera_id: 1,
         executable: right_executable,
         calibration_path: Path.join(@calibration_dir, "stereo_right.yaml")
       ] ++ side_options}
  end

  defp write_script(tmp_dir, name, script) do
    path = Path.join(tmp_dir, name)
    File.write!(path, "#!/bin/sh\n#{script}\n")
    File.chmod!(path, 0o755)
    path
  end

  test "a camera Port that exits restarts the stereo unit", %{tmp_dir: tmp_dir} do
    frame_path = write_frame(tmp_dir)

    exiting =
      write_script(
        tmp_dir,
        "exiting_camera.sh",
        "sleep 1.5\ncat \"#{frame_path}\"\nsleep 0.3\nexit 3"
      )

    idle = write_script(tmp_dir, "idle_camera.sh", "cat > /dev/null")

    start_pipeline(%VisionCore.Config{components: [stereo_component(exiting, idle)]})

    :ok = VisionCore.Outputs.subscribe({:camera_frame, LibCamera.name_for("left")})
    stereo = VisionCore.Stereo.Supervisor

    assert stereo |> child_ids() |> Enum.reverse() == [
             {:stereo, :driver, :left},
             {:stereo, :driver, :right},
             VisionCore.Stereo.Pipeline,
             VisionCore.Stereo.Pairer,
             VisionCore.Stereo.AlignmentCorrection,
             {:stereo, :parameters}
           ]

    first_driver = child_pid(stereo, {:stereo, :driver, :left})
    assert_receive {:"$gen_cast", {:camera_frame, %Frame{frame_id: "stereo_left"}}}, 5_000

    second_driver = wait_for_new_driver(stereo, first_driver)
    refute second_driver == first_driver
    assert_receive {:"$gen_cast", {:camera_frame, _frame}}, 5_000
  end

  test "a camera Port that exits at start leaves the stereo unit down, not the pipeline",
       %{tmp_dir: tmp_dir} do
    start_failing_cameras(tmp_dir, "exit 3")
    assert_stereo_unit_down()
  end

  test "a camera Port that keeps exiting stops the stereo unit, not the pipeline nor the exporters",
       %{tmp_dir: tmp_dir} do
    start_failing_cameras(tmp_dir, "cat \"#{write_frame(tmp_dir)}\"\nsleep 0.3\nexit 3")
    assert Process.whereis(VisionCore.Stereo.Supervisor)
    exporter = child_pid(VisionCore.Exporters, :ros2)
    assert is_pid(exporter)

    assert_stereo_unit_down()

    assert child_pid(VisionCore.Exporters, :ros2) == exporter
    assert VisionCore.Status.snapshot().sync == %{present: false}
  end

  defp start_failing_cameras(tmp_dir, script) do
    failing = write_script(tmp_dir, "failing_camera.sh", script)

    start_pipeline(%VisionCore.Config{
      ros2: @ros2,
      components: [stereo_component(failing, failing)],
      exporters: [{VisionCore.Ros2.Exporter, stereo: []}]
    })
  end

  # Cameras that start and stay silent: the stereo unit runs, with nothing to restart it.
  defp start_idle_unit(tmp_dir) do
    idle = write_script(tmp_dir, "idle_camera.sh", "cat > /dev/null")

    start_pipeline(%VisionCore.Config{
      ros2: @ros2,
      components: [stereo_component(idle, idle, startup_timeout_ms: 60_000)],
      exporters: [{VisionCore.Ros2.Exporter, heartbeat: [], stereo: []}]
    })

    stereo_processes()
  end

  defp stereo_processes do
    for {id, pid, _type, _modules} <- Supervisor.which_children(VisionCore.Stereo.Supervisor),
        do: {id, pid}
  end

  # Kills the exporter's `child` whenever it runs, until the exporter's supervisor gives up.
  defp crash_loop(exporter, child) do
    case child_pid(VisionCore.Exporters, exporter) do
      :undefined ->
        :ok

      supervisor ->
        case List.keyfind(Supervisor.which_children(supervisor), child, 0) do
          {^child, pid, _type, _modules} when is_pid(pid) -> Process.exit(pid, :kill)
          _restarting -> :ok
        end

        Process.sleep(20)
        crash_loop(exporter, child)
    end
  end

  test "a ROS 2 exporter that keeps crashing stops alone: the stereo unit runs on as it was",
       %{tmp_dir: tmp_dir} do
    stereo = start_idle_unit(tmp_dir)
    exporters = Process.whereis(VisionCore.Exporters)
    status = Process.whereis(VisionCore.Status)

    crash_loop(:ros2, VisionCore.Exporter.Runner)

    assert stereo_processes() == stereo
    assert Process.whereis(VisionCore.Exporters) == exporters
    assert Process.whereis(VisionCore.Status) == status
    assert [%{id: "ros2", status: {:off, _detail}}] = VisionCore.Exporters.list()
  end

  test "a diagnostics helper that keeps crashing stops the ROS 2 exporter alone: the stereo unit runs on as it was",
       %{tmp_dir: tmp_dir} do
    stereo = start_idle_unit(tmp_dir)
    exporters = Process.whereis(VisionCore.Exporters)

    crash_loop(:ros2, VisionCore.Ros2.Exporter.Diagnostics)

    assert stereo_processes() == stereo
    assert Process.whereis(VisionCore.Exporters) == exporters
  end

  test "a ROS 2 camera source without ros2: leaves its unit down, with the reason logged, and the unit runs" do
    log =
      capture_log(fn ->
        start_pipeline(%VisionCore.Config{
          components: [
            {:stereo,
             driver: VisionCore.Ros2.Camera,
             width: 64,
             height: 48,
             left: [
               topic: "stereo/left/image_raw/compressed",
               calibration_path: Path.join(@calibration_dir, "stereo_left.yaml")
             ],
             right: [
               topic: "stereo/right/image_raw/compressed",
               calibration_path: Path.join(@calibration_dir, "stereo_right.yaml")
             ]}
          ]
        })
      end)

    assert log =~
             "cannot read stereo/left/image_raw/compressed: the vision configuration has no ros2: section"

    assert Process.whereis(VisionCore.Stereo.Supervisor) == nil
    assert Process.alive?(Process.whereis(VisionCore.Status))
  end

  for {malformed, options} <- [
        {"a side that is not a list", [left: :front]},
        {"no driver", [driver: nil]}
      ] do
    test "a stereo component with #{malformed} leaves its unit down and the ROS 2 exporter not started, and the unit runs",
         %{tmp_dir: tmp_dir} do
      idle = write_script(tmp_dir, "idle_camera.sh", "cat > /dev/null")
      {:stereo, stereo_options} = stereo_component(idle, idle)

      log =
        capture_log(fn ->
          start_pipeline(%VisionCore.Config{
            ros2: @ros2,
            components: [{:stereo, Keyword.merge(stereo_options, unquote(options))}],
            exporters: [{VisionCore.Ros2.Exporter, stereo: []}]
          })
        end)

      assert log =~ "VisionCore.Ros2.Exporter not started: "
      assert Process.whereis(VisionCore.Stereo.Supervisor) == nil
      assert [%{id: "ros2", status: {:off, _detail}}] = VisionCore.Exporters.list()
      assert Process.alive?(Process.whereis(VisionCore.Status))
      assert Process.alive?(Process.whereis(VisionCore.Preview))
    end
  end

  defp assert_stereo_unit_down do
    pipeline = Process.whereis(VisionCore.Supervisor)
    status = Process.whereis(VisionCore.Status)
    wait_until_stopped(VisionCore.Stereo.Supervisor)

    assert Process.whereis(VisionCore.Supervisor) == pipeline
    assert Process.whereis(VisionCore.Status) == status
    assert Process.alive?(Process.whereis(VisionCore.Preview))

    assert %{cameras: %{left: %{present: false}, right: %{present: false}}} =
             VisionCore.Status.snapshot()
  end

  defp wait_until_stopped(name, attempts \\ 300) do
    cond do
      Process.whereis(name) == nil ->
        :ok

      attempts > 0 ->
        Process.sleep(50)
        wait_until_stopped(name, attempts - 1)

      true ->
        flunk("#{inspect(name)} kept running")
    end
  end

  defp eventually(check, attempts \\ 60) do
    cond do
      check.() -> true
      attempts > 0 -> Process.sleep(50) && eventually(check, attempts - 1)
      true -> false
    end
  end

  defp wait_for_restart(name, old_pid, attempts \\ 100) do
    case Process.whereis(name) do
      pid when is_pid(pid) and pid != old_pid ->
        :sys.get_state(pid)

      _ when attempts > 0 ->
        Process.sleep(50)
        wait_for_restart(name, old_pid, attempts - 1)

      _ ->
        flunk("#{inspect(name)} was not restarted")
    end
  end

  defp wait_for_new_driver(stereo, old_pid, attempts \\ 100) do
    case child_pid(stereo, {:stereo, :driver, :left}) do
      pid when is_pid(pid) and pid != old_pid ->
        pid

      _ when attempts > 0 ->
        Process.sleep(50)
        wait_for_new_driver(stereo, old_pid, attempts - 1)

      _ ->
        flunk("the left camera driver was not restarted")
    end
  end

  # A group owned by the test: a bare configuration declares none.
  defp declare_sample do
    {:ok, value} = Agent.start_link(fn -> 1 end)

    :ok =
      VisionCore.Parameters.declare([
        %{
          id: "test.sample",
          name: "Sample",
          summary: "A test parameter.",
          kind: :component,
          pipeline: :detection,
          position: 0,
          parameters: [
            %{
              name: "value",
              type: :integer,
              get: fn -> Agent.get(value, & &1) end,
              set: fn new -> Agent.update(value, fn _old -> new end) end,
              constraint: %{kind: :range, min: 0, max: 10, step: nil},
              description: "A sample value"
            }
          ]
        }
      ])
  end
end
