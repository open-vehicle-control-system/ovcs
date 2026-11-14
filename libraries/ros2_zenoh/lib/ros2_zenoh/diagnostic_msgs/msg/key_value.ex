defmodule Ros2Zenoh.DiagnosticMsgs.Msg.KeyValue do
  @moduledoc """
  The definition of ROS 2 `diagnostic_msgs/KeyValue`, which the
  `DiagnosticArray` schema names. `DiagnosticArray.encode/1` encodes the
  values itself, from `{key, value}` tuples.
  """

  def msg_definition do
    """
    # What to label this value when viewing.
    string key
    # A value to track over time.
    string value
    """
  end

  def dependencies, do: []
end
