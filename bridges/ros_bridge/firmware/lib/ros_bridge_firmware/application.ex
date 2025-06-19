defmodule ROSBridgeFirmware.Application do
  @moduledoc false

  use Application
  require Logger

  @impl true
  def start(_type, _args) do
    target = Application.get_env(:ros_bridge_firmware, :target)
    children = children(target)
    opts = [strategy: :one_for_one, name: ROSBridgeFirmware.Supervisor]
    Supervisor.start_link(children, opts)
  end

  def children(:host) do
    [
      {BNO085.Dummy, []},
      {ZenohMQTTRos2.Dispatcher, []},
      {ROSBridgeFirmware.JoyInterpreter, []},
      {ROSBridgeFirmware.ImuPublisher, [bno085_module: BNO085.Dummy]}
    ]
  end

  def children(_target) do
    [
      {BNO085.I2C, []},
      {ZenohMQTTRos2.Dispatcher, []},
      {ROSBridgeFirmware.JoyInterpreter, []},
      {ROSBridgeFirmware.ImuPublisher, [bno085_module: BNO085.I2C]}
    ]
  end
end
