defmodule VisionCore.ApplicationTest do
  use ExUnit.Case, async: false

  alias VisionCore.Camera.LibCamera

  @moduletag :tmp_dir
  @calibration_dir Path.expand("../support/calibration", __DIR__)

  defmodule Composer do
    @behaviour VisionCore.Composer

    @impl VisionCore.Composer
    def config(_arm), do: Application.fetch_env!(:vision_core, :test_config)
  end

  setup do
    Application.stop(:vision_core)

    on_exit(fn ->
      Application.stop(:vision_core)
      Application.delete_env(:vision_core, :vehicle)
      Application.delete_env(:vision_core, :test_config)
      Application.ensure_all_started(:vision_core)
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

  test "a composer's components start under VisionCore.Supervisor" do
    start_pipeline(%VisionCore.Config{zenoh_endpoint_ip: "127.0.0.1", components: [:heartbeat]})

    ids = child_ids(VisionCore.Supervisor)
    assert VisionCore.Ros2.ZenohClient in ids
    assert VisionCore.Ros2.Parameters in ids
    assert VisionCore.Ros2.Publishers.Heartbeat in ids
    assert Enum.take(ids, 2) == [VisionCore.Preview, VisionCore.Status]
  end

  test "settings are the config the pipeline started with" do
    start_pipeline(%VisionCore.Config{zenoh_endpoint_ip: "127.0.0.1", components: [:heartbeat]})

    Application.put_env(:vision_core, :test_config, %VisionCore.Config{
      zenoh_endpoint_ip: "10.0.0.9"
    })

    assert %{"zenoh_endpoint_ip" => "127.0.0.1"} = VisionCore.settings()

    Application.stop(:vision_core)
    assert VisionCore.settings() == %{}
  end

  test "the pipeline keeps running with no Zenoh router" do
    start_pipeline(%VisionCore.Config{zenoh_endpoint_ip: "127.0.0.1", components: [:heartbeat]})

    Process.sleep(2_000)

    assert Process.whereis(VisionCore.Supervisor) |> Process.alive?()
    assert Process.whereis(VisionCore.Ros2.ZenohClient) |> Process.alive?()
  end

  test "a camera Port that exits restarts the stereo unit", %{tmp_dir: tmp_dir} do
    jpeg = Evision.imencode(".jpg", Evision.Mat.zeros({48, 64}, :u8))
    frame = <<1, 64::little-16, 48::little-16, 0::little-64, byte_size(jpeg)::little-32>> <> jpeg
    frame_path = Path.join(tmp_dir, "frame.bin")
    File.write!(frame_path, <<byte_size(frame)::big-32>> <> frame)

    exiting = Path.join(tmp_dir, "exiting_camera.sh")

    File.write!(exiting, """
    #!/bin/sh
    sleep 1.5
    cat "#{frame_path}"
    sleep 0.3
    exit 3
    """)

    idle = Path.join(tmp_dir, "idle_camera.sh")
    File.write!(idle, "#!/bin/sh\ncat > /dev/null\n")
    File.chmod!(exiting, 0o755)
    File.chmod!(idle, 0o755)

    start_pipeline(%VisionCore.Config{
      zenoh_endpoint_ip: "127.0.0.1",
      components: [
        {:stereo_camera,
         driver: LibCamera,
         width: 64,
         height: 48,
         fps: 5,
         left: [
           camera_id: 0,
           executable: exiting,
           calibration_path: Path.join(@calibration_dir, "stereo_left.yaml")
         ],
         right: [
           camera_id: 1,
           executable: idle,
           calibration_path: Path.join(@calibration_dir, "stereo_right.yaml")
         ]}
      ]
    })

    stereo = VisionCore.StereoCamera.Supervisor
    first_driver = child_pid(stereo, {:stereo, :driver, :left})
    LibCamera.register_listener(first_driver, self())
    assert_receive {:"$gen_cast", {:camera_frame, _frame}}, 5_000

    second_driver = wait_for_new_driver(stereo, first_driver)
    refute second_driver == first_driver
    LibCamera.register_listener(second_driver, self())
    assert_receive {:"$gen_cast", {:camera_frame, _frame}}, 5_000
  end

  test "a camera Port that exits at start leaves the stereo unit down, not the pipeline",
       %{tmp_dir: tmp_dir} do
    start_failing_cameras(tmp_dir, "exit 3")
    assert_stereo_unit_down()
  end

  test "a camera Port that keeps exiting stops the stereo unit, not the pipeline",
       %{tmp_dir: tmp_dir} do
    start_failing_cameras(tmp_dir, "sleep 0.3\nexit 3")
    assert Process.whereis(VisionCore.StereoCamera.Supervisor)
    assert_stereo_unit_down()
  end

  defp start_failing_cameras(tmp_dir, script) do
    failing = Path.join(tmp_dir, "failing_camera.sh")
    File.write!(failing, "#!/bin/sh\n#{script}\n")
    File.chmod!(failing, 0o755)

    start_pipeline(%VisionCore.Config{
      zenoh_endpoint_ip: "127.0.0.1",
      components: [
        {:stereo_camera,
         driver: LibCamera,
         width: 64,
         height: 48,
         fps: 5,
         left: [
           camera_id: 0,
           executable: failing,
           calibration_path: Path.join(@calibration_dir, "stereo_left.yaml")
         ],
         right: [
           camera_id: 1,
           executable: failing,
           calibration_path: Path.join(@calibration_dir, "stereo_right.yaml")
         ]}
      ]
    })
  end

  defp assert_stereo_unit_down do
    pipeline = Process.whereis(VisionCore.Supervisor)
    status = Process.whereis(VisionCore.Status)
    wait_until_stopped(VisionCore.StereoCamera.Supervisor)

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
end
