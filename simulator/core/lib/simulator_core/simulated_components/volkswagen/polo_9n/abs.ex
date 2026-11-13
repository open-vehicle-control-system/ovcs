defmodule SimulatorCore.SimulatedComponents.Volkswagen.Polo9N.ABS do
  @moduledoc """
  A Volkswagen Polo 9N ABS unit, the inverse of
  `VmsCore.Components.Volkswagen.Polo9N.ABS`: the vehicle speed on
  `abs_status` and the four wheel speeds on `wheels_speed`, in km/h and
  without direction, as the unit reports them. Every wheel reports the
  vehicle's measured speed: `SimulatorCore.Vehicle` has one.

  ## Options

    * `:network` (required) — the ABS unit's network.
  """
  @behaviour SimulatorCore.SimulatedComponent

  import SimulatorCore.SimulatedComponent, only: [decimal: 2]

  @km_h_per_m_s 3.6
  @wheels ~w(front_left_wheel_speed front_right_wheel_speed rear_left_wheel_speed rear_right_wheel_speed)

  @impl SimulatorCore.SimulatedComponent
  def init(opts) do
    state = %{network: opts |> Map.new() |> Map.fetch!(:network)}
    {state, [], frames(state, 0.0)}
  end

  @impl SimulatorCore.SimulatedComponent
  def report(state, vehicle, _now_ms),
    do: {state, frames(state, abs(vehicle.measured_speed_m_s) * @km_h_per_m_s)}

  defp frames(state, speed_km_h) do
    speed = decimal(speed_km_h, 3)

    [
      {state.network, "abs_status", %{"filler0" => 0, "speed" => speed}},
      {state.network, "wheels_speed", Map.new(@wheels, &{&1, speed})}
    ]
  end
end
