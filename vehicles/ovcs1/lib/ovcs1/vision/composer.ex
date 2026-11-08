defmodule Ovcs1.Vision.Composer do
  @moduledoc """
  OVCS1's vision unit: an Arduino VENTUNO Q with two Raspberry Pi Global
  Shutter Cameras (IMX296) on Camera 0 (left) and Camera 1 (right), 20 cm
  apart with 6 mm lenses.

  `priv/firmware/vision/rootfs_overlay/boot/cameras.cfg` names the sensor on
  each of the board's connectors.
  """

  @behaviour VisionCore.Composer

  @impl VisionCore.Composer
  def config(:host) do
    %VisionCore.Config{
      ros2: [zenoh_endpoint_ip: System.get_env("ZENOH_ENDPOINT_IP", "127.0.0.1")],
      exporters: [{VisionCore.Ros2.Exporter, heartbeat: []}]
    }
  end

  def config(:target) do
    %VisionCore.Config{
      ros2: [
        zenoh_endpoint_ip: Application.get_env(:vision_core, :zenoh_endpoint_ip, "127.0.0.1")
      ],
      exporters: [{VisionCore.Ros2.Exporter, heartbeat: []}]
    }
  end
end
