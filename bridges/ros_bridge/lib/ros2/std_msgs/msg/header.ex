defmodule Ros2.StdMsgs.Msg.Header do
  @moduledoc """
  ROS 2 `std_msgs/Header`: a `builtin_interfaces/Time` followed by a
  length-prefixed `frame_id` string. The CDR alignment tail after
  `encode/1` is 4 bytes (string padding); callers nesting a Header
  inside a larger message must `Ros2.Common.align_to(buffer, 8)`
  before any subsequent `float64` field.
  """
  use Ros2.Common

  alias Ros2.BuiltinInterfaces.Msg.Time

  defstruct stamp: nil, frame_id: ""

  def encode(%__MODULE__{stamp: stamp, frame_id: frame_id}) do
    Time.encode(stamp) <> encode_string(frame_id)
  end

  def parse(payload) do
    with {:ok, stamp, payload} <- Time.parse(payload),
         {:ok, frame_id, payload} <- parse_string(payload) do
      {:ok, %__MODULE__{stamp: stamp, frame_id: frame_id}, payload}
    else
      error -> error
    end
  end
end
