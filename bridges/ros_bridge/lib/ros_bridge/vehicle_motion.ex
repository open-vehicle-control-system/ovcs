defmodule RosBridge.VehicleMotion do
  @moduledoc """
  The VMS's `vehicle_motion` CAN frame (`0x60B`), as the publishers
  that read it share it: its name, and the distance its wrapping
  counter says the wheels rolled between two samples.
  """

  @frame_name "vehicle_motion"
  # The frame's distance signal is 16 bits unsigned at 1 mm per count.
  @distance_wrap_m 65.536
  # A larger step is a restarted counter, not distance rolled.
  @max_distance_step_m 0.5

  def frame_name, do: @frame_name

  @doc """
  The signed distance from `previous_m` to `distance_m`, unwrapped
  across the counter's wrap; nil for a step too long to have been
  rolled between two samples.

      iex> RosBridge.VehicleMotion.distance_step(65.53, 0.004) |> Float.round(6)
      0.01
      iex> RosBridge.VehicleMotion.distance_step(1.0, 3.0)
      nil
  """
  @spec distance_step(float(), float()) :: float() | nil
  def distance_step(previous_m, distance_m) do
    delta_m = distance_m - previous_m
    half_wrap_m = @distance_wrap_m / 2
    step_m = delta_m - @distance_wrap_m * Float.floor((delta_m + half_wrap_m) / @distance_wrap_m)
    if abs(step_m) <= @max_distance_step_m, do: step_m
  end
end
