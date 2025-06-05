defmodule ROSBridgeFirmware.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  require Logger

  @impl true
  def start(_type, _args) do
    target = Application.get_env(:ros_bridge_firmware, :target)

    if target != :host do
      # Enable multicast on the loopback interface
      System.cmd("ip", ["link", "set", "lo", "multicast", "on"])
    end
    children = children(target)
    opts = [strategy: :one_for_one, name: ROSBridgeFirmware.Supervisor]
    Supervisor.start_link(children, opts)
  end

  def children(:host) do
    [
      {BNO085.Dummy, []}
    ]
  end

  def children(_target) do
    [
      {BNO085.I2C, []}
    ] ++ zenoh_bridge_ros2dds()
  end

  def logger_fun_fun(line, prefix \\ "") do
    require Logger
    Logger.info([prefix, line])
  end

  def zenoh_bridge_ros2dds() do
    zenoh_bridge_ros2dds = "/bin/zenoh-bridge-ros2dds"
    zenoh_endpoint_ip = Application.get_env(:ros_bridge_firmware, :zenoh_endpoint_ip)

    if File.exists?(zenoh_bridge_ros2dds) and not is_nil(zenoh_endpoint_ip) do
      Logger.info("start zenoh-bridge-dds, server is #{zenoh_endpoint_ip}")
      [
        %{
          id: ZenohBridge,
          start: {ROSBridgeFirmware.DelayedZenohBridge, :start_link, [[
            "/bin/zenoh-bridge-ros2dds",
            ["-c", "/etc/zenoh.json5"],
            [logger_fun: {__MODULE__, :logger_fun_fun}]
          ]]}
        }
      ]
    else
      []
    end
  end
end
