defmodule Ros2Zenoh.SensorMsgs.Msg.JointState do
  @moduledoc """
  ROS 2 `sensor_msgs/JointState`: per joint, by index into `name`, its
  `position`, `velocity` and `effort`. Any of the three may be empty.
  """

  import Ros2Zenoh.Cdr
  alias Ros2Zenoh.StdMsgs.Msg.Header

  defstruct header: %Header{}, name: [], position: [], velocity: [], effort: []

  # RIHS01 hash for ROS 2 Lyrical; it changes with the distro.
  @dds_type "sensor_msgs::msg::dds_::JointState_"
  @type_hash "RIHS01_a13ee3a330e346c9d87b5aa18d24e11690752bd33a0350f11c5882bc9179260e"

  def dds_type, do: @dds_type
  def type_hash, do: @type_hash

  def encode(%__MODULE__{} = joint_state) do
    Header.encode(joint_state.header)
    |> sequence(joint_state.name, &string/2)
    |> sequence(joint_state.position, &f64/2)
    |> sequence(joint_state.velocity, &f64/2)
    |> sequence(joint_state.effort, &f64/2)
  end

  def parse(body) when is_binary(body) do
    with {:ok, header, rest} <- Header.parse(body) do
      input = {rest, byte_size(body) - byte_size(rest)}
      {name, input} = read_sequence(input, &read_string/1)
      {position, input} = read_sequence(input, &read_f64/1)
      {velocity, input} = read_sequence(input, &read_f64/1)
      {effort, {rest, _offset}} = read_sequence(input, &read_f64/1)

      {:ok,
       %__MODULE__{
         header: header,
         name: name,
         position: position,
         velocity: velocity,
         effort: effort
       }, rest}
    end
  end
end
