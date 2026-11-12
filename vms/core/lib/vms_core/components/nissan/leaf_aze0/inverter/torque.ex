defmodule VmsCore.Components.Nissan.LeafAZE0.Inverter.Torque do
  @moduledoc "The Leaf inverter's signed torque request for the selected gear and throttle."
  @moduledoc safety: :relevant
  alias Decimal, as: D

  @zero D.new(0)

  @doc "Returns the torque selected by the gear, throttle threshold and vehicle limits."
  def request(state) do
    max_torque =
      case state.selected_gear do
        :drive -> state.drive_max_torque_nm
        :reverse -> D.negate(state.reverse_max_torque_nm)
        _ -> @zero
      end

    requested_throttle =
      case D.lt?(state.requested_throttle, state.effective_throttle_threshold) do
        true -> @zero
        false -> state.requested_throttle
      end

    D.mult(requested_throttle, max_torque)
  end
end
