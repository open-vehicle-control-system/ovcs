defmodule OvcsMini do
  @moduledoc """
  Top-level entry point for the OVCS Mini vehicle package.

  OVCS Mini has no infotainment side.
  """
  @behaviour OvcsVehicle
  @behaviour RadioControlBridge
  @behaviour RosBridge

  @impl OvcsVehicle
  def name, do: "OVCS Mini"
  @impl OvcsVehicle
  def vms, do: OvcsMini.Vms.Composer
  @impl OvcsVehicle
  def can_config_otp_app, do: :ovcs_mini
  @impl OvcsVehicle
  def vms_target, do: :ovcs_base_can_system_rpi4

  @impl OvcsVehicle
  def bridge_firmwares do
    %{
      "radio_control" => %{
        target: :ovcs_base_can_system_rpi3a,
        bridges: [RadioControlBridge],
        default_can_mapping: %{host: "ovcs:vcan0", target: "ovcs:spi0.0"}
      },
      "ros" => %{
        target: :ovcs_base_can_system_rpi4,
        bridges: [RosBridge],
        default_can_mapping: %{host: "ovcs:vcan0", target: "ovcs:spi0.0"}
      },
      # Perception bridge: stereo Pi cameras + Hailo inference on a
      # Pi 5 + Hailo hat. Uses upstream nerves_system_rpi5 (libcamera
      # and HailoRT are already in the system; see
      # bridges/firmware/mix.exs).
      # Perception bridge: no local CAN transceiver — it joins the
      # bus over Zenoh on a separate Pi. The target mapping still
      # has to satisfy Cantastic's "valid network" contract, so we
      # point it at a virtual CAN device. Cantastic auto-creates
      # vcan0 at boot (`ip link add dev vcan0 type vcan`), so this
      # is zero-config on the Pi 5; no SPI/MCP251xFD wait needed.
      "ros_perception" => %{
        target: :rpi5,
        bridges: [RosBridge],
        default_can_mapping: %{host: "ovcs:vcan0", target: "ovcs:vcan0"}
      }
    }
  end

  @impl RadioControlBridge
  def radio_control_bridge_config(:host),
    do: %RadioControlBridge.Config{components: []}

  def radio_control_bridge_config(:target),
    do: %RadioControlBridge.Config{
      components: [
        {:mavlink_forwarder, uart_port: "ttySC0", uart_baud_rate: 460_800}
        # MSP OSD path — declared but not enabled. Strip the leading
        # `# ` from the data line below and replace the UART with the
        # actual VTX serial line once `RadioControlBridge.MspOsdForwarder`
        # ships a real impl. (The leading comma is intentional so
        # enabling is a clean prefix removal — no other edits needed.)
        # , {:msp_osd_forwarder, uart_port: "ttyXXX", uart_baud_rate: 115_200}
      ]
    }

  @impl RosBridge
  def ros_bridge_config(:host, "ros_perception"),
    do: perception_host_config()

  def ros_bridge_config(:target, "ros_perception"),
    do: perception_target_config()

  def ros_bridge_config(:host, _firmware_id),
    do: ros_host_config()

  def ros_bridge_config(:target, _firmware_id),
    do: ros_target_config()

  defp ros_host_config,
    do: %RosBridge.Config{
      zenoh_endpoint_ip: System.get_env("ZENOH_ENDPOINT_IP", "127.0.0.1"),
      components: [
        :heartbeat,
        :joy_interpreter,
        {:imu_publisher, driver: OvcsDrivers.Imu.Dummy}
      ]
    }

  defp ros_target_config,
    do: %RosBridge.Config{
      zenoh_endpoint_ip: Application.get_env(:ros_bridge, :zenoh_endpoint_ip, "127.0.0.1"),
      components: [
        :heartbeat,
        :joy_interpreter,
        {:imu_publisher, driver: BNO085.I2C}
      ]
    }

  defp perception_host_config do
    %RosBridge.Config{
      zenoh_endpoint_ip: System.get_env("ZENOH_ENDPOINT_IP", "127.0.0.1"),
      components: [
        :heartbeat,
        stereo_component(RosBridge.Camera.GStreamer, :host)
      ]
    }
  end

  defp perception_target_config do
    %RosBridge.Config{
      zenoh_endpoint_ip: Application.get_env(:ros_bridge, :zenoh_endpoint_ip, "127.0.0.1"),
      components: [
        :heartbeat,
        stereo_component(RosBridge.Camera.LibCamera, :target)
      ]
    }
  end

  # Self-contained stereo perception block. Inherits most defaults
  # from `RosBridge.StereoCamera.Supervisor` (backend
  # `StereoCamera.OpenCV`, topic prefix `"stereo"`, frame_ids
  # `stereo_left` / `stereo_right`, calibration paths
  # `<calibration_dir>/stereo_<side>.yaml`). We override resolution
  # and SGBM parameters here to keep the disparity rate usable on a
  # laptop CPU (≈ 2 Hz at 640×480, vs ≈ 0.7 Hz at 1280×720).
  #
  # Host note: each USB camera must be on a *separate* USB
  # controller. uvcvideo reserves isochronous bandwidth on the
  # worst-case (uncompressed) basis, so two MJPEG streams on the
  # same USB 2 hub will fail with "Buffer pool activation failed".
  defp stereo_component(camera_driver, arm) do
    {:stereo_camera,
     driver: camera_driver,
     calibration_dir: priv_calibration_dir(),
     # 640×480 is the standard low-bandwidth UVC mode every webcam
     # supports natively. SGBM compute time scales roughly with
     # `width × height × num_disparities`, so 640×480 + a tighter
     # disparity range is the main speed knob.
     width: 640,
     height: 480,
     fps: 30,
     # Wide enough for the unsynchronized USB cameras on host;
     # drop to 5 ms once the perception target has FSIN-tied CSI
     # modules.
     pair_tolerance_ms: 100,
     # num_disparities=48 → caps the minimum visible distance at
     # ~(f × baseline) / 48 metres but cuts the SGBM inner loop by
     # 25 % vs the previous 64. Must stay a multiple of 16.
     # block_size=7 is a balanced point between bs=5 (denser
     # coverage but jittery) and bs=9 (stable but sparse) — gives
     # ~30 % more frame-to-frame stability for ~5 pp coverage cost.
     backend_opts: [num_disparities: 48, block_size: 7],
     left: camera_addressing(arm, :left),
     right: camera_addressing(arm, :right)}
  end

  defp camera_addressing(:host, :left), do: [device: "/dev/video2"]
  defp camera_addressing(:host, :right), do: [device: "/dev/video0"]
  # Perception bridge has both CSI modules mounted upside down on the
  # OVCS Mini stereo bar — rotate 180° in-pipeline so downstream
  # consumers (rectification + SGBM, Foxglove) see them right-way-up.
  defp camera_addressing(:target, :left), do: [camera_id: 0, rotation: 180]
  defp camera_addressing(:target, :right), do: [camera_id: 1, rotation: 180]

  defp priv_calibration_dir do
    case :code.priv_dir(:ovcs_mini) do
      {:error, :bad_name} -> "priv/calibration"
      dir -> Path.join(List.to_string(dir), "calibration")
    end
  end
end
