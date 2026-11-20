defmodule OvcsVehicle.VehiclePath do
  @moduledoc """
  Where a vehicle package lives, for the firmwares' config files and `mix.exs`, which run
  before any dependency compiles and so load this file with `Code.require_file/2`.
  """

  @doc """
  The vehicle package's folder: `OVCS_VEHICLE_PATH` when set, else `vehicles/<vehicle_dir>`
  of the OVCS checkout at `ovcs_root`.
  """
  @spec root(String.t(), Path.t()) :: Path.t()
  def root(vehicle_dir, ovcs_root) do
    case System.get_env("OVCS_VEHICLE_PATH") do
      path when path in [nil, ""] -> Path.join([ovcs_root, "vehicles", vehicle_dir])
      path -> Path.expand(path)
    end
  end
end
