defmodule Ros2.GeometryMsgs.Msg.Quaternion do
  @moduledoc false
  use Ros2.Common

  defstruct [:x, :y, :z, :w]

  def parse(<<x::little-float-64, y::little-float-64, z::little-float-64, w::little-float-64, rest::binary>>) do
    {:ok, %__MODULE__{x: x, y: y, z: z, w: w}, rest}
  rescue
    _ -> {:error, :malformed, __MODULE__}
  end
end
