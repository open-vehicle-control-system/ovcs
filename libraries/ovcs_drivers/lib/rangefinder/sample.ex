defmodule OvcsDrivers.Rangefinder.Sample do
  @moduledoc """
  One measurement from a module implementing `OvcsDrivers.Rangefinder`.

    * `:distance` — metres, or `:below_range` / `:beyond_range` when the
      sensor reports something outside `:range`
    * `:range` — `{min, max}` metres the sensor measures
    * `:field_of_view` — the beam's full angle, radians
    * `:measured_at` — system time in nanoseconds
  """
  @enforce_keys [:distance, :range, :field_of_view, :measured_at]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          distance: float() | :below_range | :beyond_range,
          range: {float(), float()},
          field_of_view: float(),
          measured_at: integer()
        }
end
