defmodule Ros2.GeometryMsgs.Msg.Vector3 do
  @moduledoc """
  ROS 2 `geometry_msgs/Vector3`: three `float64`s (x, y, z), 24 bytes
  total. Callers must ensure the encode buffer is 8-aligned before
  nesting this struct.
  """
  use Ros2.Common

  defstruct x: 0.0, y: 0.0, z: 0.0

  def encode(%__MODULE__{x: x, y: y, z: z}) do
    encode_float64(x) <> encode_float64(y) <> encode_float64(z)
  end

  def parse(<<x::little-float-64, y::little-float-64, z::little-float-64, rest::binary>>) do
    {:ok, %__MODULE__{x: x, y: y, z: z}, rest}
  end

  # A short body raises FunctionClauseError at the call site, out of
  # reach of a `rescue`, so the tagged error needs its own clause.
  def parse(body) when is_binary(body), do: {:error, :malformed, __MODULE__}
end
