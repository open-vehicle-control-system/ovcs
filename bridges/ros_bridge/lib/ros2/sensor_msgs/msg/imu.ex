defmodule Ros2.SensorMsgs.Msg.Imu do
  @moduledoc """
  ROS 2 `sensor_msgs/Imu`. Field order on the wire (per the IDL):

      Header header
      Quaternion orientation
      float64[9] orientation_covariance
      Vector3 angular_velocity
      float64[9] angular_velocity_covariance
      Vector3 linear_acceleration
      float64[9] linear_acceleration_covariance

  CDR alignment: the only hazard is the `Header` → `Quaternion`
  boundary (Header's tail is 4-aligned via the string padding;
  Quaternion's first `float64` needs 8-alignment). Every subsequent
  field is a `float64` run, so the buffer stays 8-aligned naturally.
  """
  use Ros2.Common

  alias Ros2.GeometryMsgs.Msg.Quaternion
  alias Ros2.GeometryMsgs.Msg.Vector3
  alias Ros2.StdMsgs.Msg.Header

  defstruct [
    :header,
    :orientation,
    :orientation_covariance,
    :angular_velocity,
    :angular_velocity_covariance,
    :linear_acceleration,
    :linear_acceleration_covariance
  ]

  # rmw_zenoh keyexpr metadata for `sensor_msgs/msg/Imu`. The
  # DDS-mangled type name comes from rosidl's IDL convention. The
  # RIHS01 hash was captured against ROS 2 Jazzy via
  # `ros2 topic info -v /<topic>` ("Topic type hash:" line) on an
  # rclpy publisher of `sensor_msgs/Imu`. Refresh on distro bumps.
  @dds_type "sensor_msgs::msg::dds_::Imu_"
  @type_hash "RIHS01_7d9a00ff131080897a5ec7e26e315954b8eae3353c3f995c55faf71574000b5b"

  def dds_type, do: @dds_type
  def type_hash, do: @type_hash

  def encode(%__MODULE__{} = imu) do
    Header.encode(imu.header)
    |> align_to(8)
    |> Kernel.<>(Quaternion.encode(imu.orientation))
    |> Kernel.<>(encode_float64_array_fixed(imu.orientation_covariance, 9))
    |> Kernel.<>(Vector3.encode(imu.angular_velocity))
    |> Kernel.<>(encode_float64_array_fixed(imu.angular_velocity_covariance, 9))
    |> Kernel.<>(Vector3.encode(imu.linear_acceleration))
    |> Kernel.<>(encode_float64_array_fixed(imu.linear_acceleration_covariance, 9))
  end

  def parse(payload) do
    with {:ok, header, payload} <- Header.parse(payload),
         payload <- consume_alignment(payload, 8, byte_size_after_header(header)),
         {:ok, orientation, payload} <- Quaternion.parse(payload),
         {:ok, orientation_covariance, payload} <- parse_float64_array(payload, 9),
         {:ok, angular_velocity, payload} <- Vector3.parse(payload),
         {:ok, angular_velocity_covariance, payload} <- parse_float64_array(payload, 9),
         {:ok, linear_acceleration, payload} <- Vector3.parse(payload),
         {:ok, linear_acceleration_covariance, payload} <-
           parse_float64_array(payload, 9) do
      {:ok,
       %__MODULE__{
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

  # CDR alignment is relative to the start of the encapsulated body,
  # but `Header.parse/1` consumes a variable number of bytes (the
  # frame_id string). To know how much padding precedes the next
  # 8-aligned field we have to know the body-relative offset *after*
  # Header — i.e. how many bytes Header.encode/1 would have produced
  # for the same struct.
  defp byte_size_after_header(header), do: byte_size(Header.encode(header))

end
