defmodule VmsCore.Managers.Gear.Selection do
  @moduledoc "Selects a gear from the ignition, readiness, motion and driver request."
  @moduledoc safety: :relevant

  alias Decimal, as: D

  @gear_shift_throttle_limit D.new("0.05")
  @gear_shift_speed_limit_km_h D.new("1")

  @doc "The gear to engage, or nil to keep the selected gear."
  def next_gear(state) do
    %{
      contact: contact,
      requested_gear: requested_gear,
      selected_gear: selected_gear,
      ready_to_drive: ready_to_drive,
      speed: speed,
      requested_throttle: requested_throttle
    } = state

    # A nil speed is a source that has gone quiet; unknown is not near zero.
    speed_near_zero =
      not is_nil(speed) and D.abs(speed) |> D.lt?(@gear_shift_speed_limit_km_h)

    throttle_near_zero = D.lt?(requested_throttle, @gear_shift_throttle_limit)
    can_engage = speed_near_zero && throttle_near_zero

    cond do
      contact == :off && selected_gear != :parking ->
        :parking

      !ready_to_drive && selected_gear in [:reverse, :drive] ->
        :neutral

      selected_gear != :parking && requested_gear == :parking && can_engage ->
        :parking

      selected_gear != :neutral && requested_gear == :neutral && ready_to_drive ->
        :neutral

      reversal?(selected_gear, requested_gear) && !can_engage ->
        :neutral

      selected_gear != requested_gear && requested_gear in [:reverse, :drive] && can_engage &&
          ready_to_drive ->
        requested_gear

      true ->
        nil
    end
  end

  defp reversal?(:drive, :reverse), do: true
  defp reversal?(:reverse, :drive), do: true
  defp reversal?(_selected_gear, _requested_gear), do: false
end
