defmodule RosBridge.Components do
  @moduledoc """
  Resolves the symbolic component entries in a vehicle's
  `RosBridge.Config.components` list into supervised child specs.

  Each clause of `start/2` returns a list of one or more child specs
  for the named component. Vehicles compose `ros_bridge` by listing
  the components they want; adding a new feature is one new clause
  here plus one opt-in line per vehicle that wants it. No implicit
  defaults — the bridge's runtime shape is exactly what the active
  vehicle declared.

  ## Components today

    * `:heartbeat` — `RosBridge.Heartbeat` publishing a 1 Hz
      `std_msgs/String` on `/ovcs_heartbeat`. Opts:
        * `:interval_ms` (default `1_000`)
    * `:joy_interpreter` — `RosBridge.JoyInterpreter` subscribing to
      `/joy` and forwarding axes onto the CAN bus. No opts.
    * `:imu_publisher` — starts the named driver (any
      `OvcsDrivers.Imu` implementation) followed by
      `RosBridge.ImuPublisher`. Opts:
        * `:driver` (required, module — `OvcsDrivers.Imu.Dummy`,
          `BNO085.I2C`, etc.)
        * `:topic`, `:frame_id`, `:publish_interval_ms` — forwarded
          to `RosBridge.ImuPublisher` (see its defaults).
  """

  @doc """
  Returns the child specs to start `component` with `opts`. Raises on
  unknown names so a typo in a vehicle's `:components` list fails
  loudly at boot.
  """
  def start(:heartbeat, opts) do
    [
      {RosBridge.Heartbeat,
       topic: "ovcs_heartbeat",
       message_module: Ros2.StdMsgs.Msg.String,
       interval_ms: Keyword.get(opts, :interval_ms, 1_000),
       build: &heartbeat_message/1}
    ]
  end

  def start(:joy_interpreter, _opts), do: [{RosBridge.JoyInterpreter, []}]

  def start(:imu_publisher, opts) do
    driver = Keyword.fetch!(opts, :driver)
    [{driver, []}, {RosBridge.ImuPublisher, opts}]
  end

  defp heartbeat_message(counter) do
    %Ros2.StdMsgs.Msg.String{
      data: "heartbeat #{counter} @ #{System.system_time(:millisecond)}"
    }
  end
end
