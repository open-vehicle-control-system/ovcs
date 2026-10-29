defmodule VisionCore.Stereo.Cloud do
  @moduledoc "Packing of point clouds for `sensor_msgs/PointCloud2`."

  @min_point_depth_m 0.05
  @max_point_depth_m 20.0

  @doc """
  Packed `x, y, z` 32-bit float points with z from 5 cm to 20 m, and
  their count: unmatched pixels (depth 0) are dropped, not packed as a
  phantom point at the origin.
  """
  @spec pack_in_range(binary()) :: {binary(), non_neg_integer()}
  def pack_in_range(binary) do
    {chunks, count} =
      for <<x::little-float-32, y::little-float-32, z::little-float-32 <- binary>>,
          z > @min_point_depth_m and z < @max_point_depth_m,
          reduce: {[], 0} do
        {chunks, count} ->
          {[<<x::little-float-32, y::little-float-32, z::little-float-32>> | chunks], count + 1}
      end

    {chunks |> Enum.reverse() |> IO.iodata_to_binary(), count}
  end
end
