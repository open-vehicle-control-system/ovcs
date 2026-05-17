defmodule Ros2.GeometryMsgs.Msg.Quaternion do
  @moduledoc """
  ROS 2 `geometry_msgs/Quaternion`: four `float64`s (x, y, z, w),
  32 bytes total. Callers must ensure the encode buffer is 8-aligned
  before nesting this struct (every `float64` field is 8-aligned in
  CDR).
  """
  use Ros2.Common

  defstruct x: 0.0, y: 0.0, z: 0.0, w: 0.0

  def encode(%__MODULE__{x: x, y: y, z: z, w: w}) do
    encode_float64(x) <> encode_float64(y) <> encode_float64(z) <> encode_float64(w)
  end

  def parse(<<x::little-float-64, y::little-float-64, z::little-float-64, w::little-float-64, rest::binary>>) do
    {:ok, %__MODULE__{x: x, y: y, z: z, w: w}, rest}
  rescue
    _ -> {:error, :malformed, __MODULE__}
  end
end
