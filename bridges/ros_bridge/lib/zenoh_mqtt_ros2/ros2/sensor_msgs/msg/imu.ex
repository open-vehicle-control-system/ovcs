defmodule Ros2.SensorMsgs.Msg.Imu do
  @moduledoc false
  use Ros2.Common

  defstruct [
    :header,
    :orientation,
    :orientation_covariance,
    :angular_velocity,
    :angular_velocity_covariance,
    :linear_acceleration,
    :linear_acceleration_covariance
  ]

  def parse(payload) do
    with {:ok, header, payload} <- Ros2.StdMsgs.Msg.Header.parse(payload),
         {:ok, orientation, payload} <- Ros2.GeometryMsgs.Msg.Quaternion.parse(payload),
         {:ok, orientation_covariance, payload} <- parse_float64_array(payload),
         {:ok, angular_velocity, payload} <- Ros2.GeometryMsgs.Msg.Vector3.parse(payload),
         {:ok, angular_velocity_covariance, payload} <- parse_float64_array(payload),
         {:ok, linear_acceleration, payload} <- Ros2.GeometryMsgs.Msg.Vector3.parse(payload),
         {:ok, linear_acceleration_covariance, payload} <- parse_float64_array(payload)
    do
      {:ok, %__MODULE__{
        header: header,
        orientation: orientation,
        orientation_covariance: orientation_covariance,
        angular_velocity: angular_velocity,
        angular_velocity_covariance: angular_velocity_covariance,
        linear_acceleration: linear_acceleration,
        linear_acceleration_covariance: linear_acceleration_covariance
      }, payload}
    else
      error -> error
    end
  end
end
