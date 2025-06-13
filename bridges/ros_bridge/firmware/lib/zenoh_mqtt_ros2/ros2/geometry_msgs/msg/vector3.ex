defmodule Ros2.GeometryMsgs.Msg.Vector3 do
  @moduledoc false
  use Ros2.Common

  defstruct [:x, :y, :z]

  def parse(
        <<x::little-float-64, y::little-float-64, z::little-float-64, rest::binary>>
      ) do
    {:ok, %__MODULE__{x: x, y: y, z: z}, rest}
  rescue
    _ -> {:error, :malformed, __MODULE__}
  end
end
