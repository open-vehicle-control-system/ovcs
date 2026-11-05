defmodule RosBridge.Imu.Mount do
  @moduledoc """
  Rotates IMU vectors and orientations into the vehicle frame using the
  fixed sensor mount's roll, pitch and yaw (radians, as in the URDF).
  """

  @doc "The quaternion rotating sensor-frame vectors into the vehicle frame."
  def quaternion({roll, pitch, yaw}) do
    cr = :math.cos(roll / 2)
    sr = :math.sin(roll / 2)
    cp = :math.cos(pitch / 2)
    sp = :math.sin(pitch / 2)
    cy = :math.cos(yaw / 2)
    sy = :math.sin(yaw / 2)

    {sr * cp * cy - cr * sp * sy, cr * sp * cy + sr * cp * sy, cr * cp * sy - sr * sp * cy,
     cr * cp * cy + sr * sp * sy}
  end

  @doc "Vehicle orientation from a world-frame sensor orientation, or nil if invalid."
  def orientation(%{x: x, y: y, z: z, w: w}, mount) do
    norm = :math.sqrt(x * x + y * y + z * z + w * w)
    if norm > 1.0e-9, do: multiply({x / norm, y / norm, z / norm, w / norm}, conjugate(mount))
  end

  @doc "A sensor-frame vector expressed in the vehicle frame."
  def vector(%{x: x, y: y, z: z}, mount) do
    {x, y, z, _w} = mount |> multiply({x, y, z, 0.0}) |> multiply(conjugate(mount))
    {x, y, z}
  end

  defp conjugate({x, y, z, w}), do: {-x, -y, -z, w}

  defp multiply({ax, ay, az, aw}, {bx, by, bz, bw}) do
    {aw * bx + ax * bw + ay * bz - az * by, aw * by - ax * bz + ay * bw + az * bx,
     aw * bz + ax * by - ay * bx + az * bw, aw * bw - ax * bx - ay * by - az * bz}
  end
end
