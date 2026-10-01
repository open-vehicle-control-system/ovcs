defmodule RosBridge.StereoCamera.PersistenceFilter do
  @moduledoc """
  Drops the cloud points the previous clouds did not see.

  A false match comes and goes between frames, while a surface stays
  where it is: a specular reflection on a glossy floor reads 7–9 cm
  above the floor in about 40 % of frames, enough to mark an obstacle
  that the next cloud clears. A point is kept when its voxel, or one of
  the 26 around it, held a point in each of the previous `:frames`
  clouds. The neighbourhood absorbs the motion between frames: with
  10 cm voxels a point may move 10 to 20 cm from one cloud to the next.

  Points are `<<x, y, z>>` little-endian float32 triples, as the stereo
  backend packs them, in any metric frame. Until `:frames` clouds have
  been seen, nothing is kept.

  ## Options

    * `:voxel_m` — voxel edge in metres (default `0.10`).
    * `:frames` — how many previous clouds must have seen a point
      (default `2`).
  """

  @enforce_keys [:voxel_m, :frames]
  defstruct [:voxel_m, :frames, history: []]

  @type t :: %__MODULE__{
          voxel_m: float(),
          frames: pos_integer(),
          history: [MapSet.t(integer())]
        }

  # Voxel indices are packed into one integer per voxel: 12 bits per
  # axis, offset so that ±2048 voxels (±204 m at 10 cm) stay positive.
  @span 4096
  @offset 2048
  @neighbours for dx <- -1..1,
                  dy <- -1..1,
                  dz <- -1..1,
                  {dx, dy, dz} != {0, 0, 0},
                  do: (dx * @span + dy) * @span + dz

  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    %__MODULE__{
      voxel_m: Keyword.get(opts, :voxel_m, 0.10) * 1.0,
      frames: Keyword.get(opts, :frames, 2)
    }
  end

  @doc """
  Filter one cloud. Returns the kept points, their count, and the state
  that remembers this cloud for the next ones.
  """
  @spec filter(t(), binary()) :: {binary(), non_neg_integer(), t()}
  def filter(%__MODULE__{} = persistence, cloud) when is_binary(cloud) do
    points =
      for <<x::little-float-32, y::little-float-32, z::little-float-32 <- cloud>>,
        do:
          {key(x, y, z, persistence.voxel_m),
           <<x::little-float-32, y::little-float-32, z::little-float-32>>}

    history = persistence.history

    {kept, count} =
      if length(history) < persistence.frames do
        {[], 0}
      else
        Enum.reduce(points, {[], 0}, fn {key, point}, {acc, n} ->
          if Enum.all?(history, &seen?(&1, key)), do: {[point | acc], n + 1}, else: {acc, n}
        end)
      end

    seen = MapSet.new(points, &elem(&1, 0))
    history = Enum.take([seen | history], persistence.frames)

    {kept |> Enum.reverse() |> IO.iodata_to_binary(), count, %{persistence | history: history}}
  end

  defp seen?(voxels, key) do
    MapSet.member?(voxels, key) or
      Enum.any?(@neighbours, &MapSet.member?(voxels, key + &1))
  end

  defp key(x, y, z, voxel_m) do
    ix = floor(x / voxel_m) + @offset
    iy = floor(y / voxel_m) + @offset
    iz = floor(z / voxel_m) + @offset
    (ix * @span + iy) * @span + iz
  end
end
