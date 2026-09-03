defmodule Ros2.GeometryMsgs.Msg.Transform do
  @moduledoc """
  ROS 2 `geometry_msgs/Transform`: a `Vector3` translation followed by
  a `Quaternion` rotation — 56 bytes of `float64`, so callers must
  ensure the encode buffer is 8-aligned before nesting this struct.
  """
  use Ros2.Common

  alias Ros2.GeometryMsgs.Msg.{Quaternion, Vector3}

  defstruct translation: %Vector3{}, rotation: %Quaternion{w: 1.0}

  def encode(%__MODULE__{translation: translation, rotation: rotation}) do
    Vector3.encode(translation) <> Quaternion.encode(rotation)
  end

  def parse(payload) do
    with {:ok, translation, payload} <- Vector3.parse(payload),
         {:ok, rotation, payload} <- Quaternion.parse(payload) do
      {:ok, %__MODULE__{translation: translation, rotation: rotation}, payload}
    end
  end
end
