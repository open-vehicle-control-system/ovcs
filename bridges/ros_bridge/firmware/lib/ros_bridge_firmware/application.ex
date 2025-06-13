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
      {BNO085.Dummy, []},
      # {ZenohMQTTRos2.Dispatcher, []},
      {ROSBridgeFirmware.JoyMessageForwarder, []}
    ]
  end

  def children(_target) do
    [
      {BNO085.I2C, []}
    ]
  end

  def logger_fun_fun(line, prefix \\ "") do
    require Logger
    Logger.info([prefix, line])
  end
end
