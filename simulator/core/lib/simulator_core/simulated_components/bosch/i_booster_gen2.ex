defmodule SimulatorCore.SimulatedComponents.Bosch.IBoosterGen2 do
  @moduledoc """
  A Bosch iBooster Gen2, the inverse of
  `VmsCore.Components.Bosch.IBoosterGen2`: its `ibooster_status`
  reports it off until its power relay is requested on a generic
  controller's digital pin request, then ready with the brakes not
  applied. The VMS reads an unpowered booster as the driver braking, as
  it does the real one.

  While powered and under an external request on `brake_request`, its
  rod moves at `:rod_speed_mm_s` times the flow rate's offset from its
  zero point over the flow rate's range, within its travel. Without an
  external request the rod springs back as fast. The vehicle decelerates
  in proportion to the rod's travel, by `:full_travel_deceleration_m_s2`
  at full travel.

  `ibooster_status` carries the rod position as three fields, one per
  segment of the frame, as `ovcs_can`'s
  `bosch/i_booster_gen2/simulated/0x39D_ibooster_status.yml` declares
  them; the shared definition reads them as one signal.

  ## Options

    * `:network` (required) — the iBooster's network.
    * `:controller` (required) — the frame-name prefix of the generic
      controller switching its power, e.g. `"front_controller"`.
    * `:controller_network` (`:ovcs`).
    * `:power_relay_pin` (required).
    * `:rod_speed_mm_s`, `:full_travel_deceleration_m_s2` (required).
  """
  @behaviour SimulatorCore.SimulatedComponent

  import SimulatorCore.SimulatedComponent, only: [float: 2]

  # The VMS's flow rates around the booster's zero point, and its rod travel.
  @zero_point_flow_rate 0x7E00
  @flow_rate_range 0x1400
  @max_rod_position_mm 16.56
  # The rod position's encoding in ibooster_status: 12 bits of 1/64 mm, from -5 mm.
  @rod_position_scale_mm 0.015625
  @rod_position_offset_mm -5

  @impl SimulatorCore.SimulatedComponent
  def init(opts) do
    opts = Map.new(opts)

    state = %{
      network: Map.fetch!(opts, :network),
      pin_request: "#{Map.fetch!(opts, :controller)}_digital_pin_request",
      controller_network: Map.get(opts, :controller_network, :ovcs),
      power_relay_pin: "digital_pin#{Map.fetch!(opts, :power_relay_pin)}_enabled",
      rod_speed_mm_s: Map.fetch!(opts, :rod_speed_mm_s),
      full_travel_deceleration_m_s2: Map.fetch!(opts, :full_travel_deceleration_m_s2),
      powered: false,
      external_request: false,
      flow_rate: @zero_point_flow_rate,
      rod_position_mm: 0.0,
      last_report_ms: nil
    }

    received = [{state.controller_network, state.pin_request}, {state.network, "brake_request"}]
    {state, received, [{state.network, "ibooster_status", ibooster_status(state)}]}
  end

  @impl SimulatorCore.SimulatedComponent
  def handle_frame(name, signals, %{pin_request: name, power_relay_pin: pin} = state, _now_ms),
    do: %{state | powered: match?(%{^pin => %{value: true}}, signals)}

  def handle_frame("brake_request", %{"external_request" => request} = signals, state, _now_ms),
    do: %{state | external_request: request.value, flow_rate: float(signals, "flow_rate")}

  @impl SimulatorCore.SimulatedComponent
  def actuations(%{rod_position_mm: rod_position_mm} = state, _vehicle, _now_ms)
      when rod_position_mm > 0,
      do: [
        {:deceleration,
         rod_position_mm / @max_rod_position_mm * state.full_travel_deceleration_m_s2}
      ]

  def actuations(_state, _vehicle, _now_ms), do: []

  @impl SimulatorCore.SimulatedComponent
  def report(state, _vehicle, now_ms) do
    state = move_rod(state, now_ms)
    {state, [{state.network, "ibooster_status", ibooster_status(state)}]}
  end

  defp move_rod(%{last_report_ms: nil} = state, now_ms), do: %{state | last_report_ms: now_ms}

  defp move_rod(state, now_ms) do
    elapsed_s = (now_ms - state.last_report_ms) / 1000
    rod_position_mm = state.rod_position_mm + rod_speed_mm_s(state) * elapsed_s

    %{
      state
      | rod_position_mm: rod_position_mm |> max(0.0) |> min(@max_rod_position_mm),
        last_report_ms: now_ms
    }
  end

  defp rod_speed_mm_s(%{powered: true, external_request: true} = state),
    do: state.rod_speed_mm_s * (state.flow_rate - @zero_point_flow_rate) / @flow_rate_range

  defp rod_speed_mm_s(state), do: -state.rod_speed_mm_s

  defp ibooster_status(state) do
    %{"crc" => 0, "counter" => 0, "internal_state" => "no_mode_active"}
    |> Map.merge(power_status(state.powered))
    |> Map.merge(rod_position_segments(state.rod_position_mm))
  end

  defp power_status(true),
    do: %{"status" => "ready", "driver_brake_apply" => "brakes_not_applied"}

  defp power_status(false), do: %{"status" => "off", "driver_brake_apply" => "not_init_or_off"}

  # The VMS reads the first segment in the frame as the lowest bits.
  defp rod_position_segments(rod_position_mm) do
    raw = round((rod_position_mm - @rod_position_offset_mm) / @rod_position_scale_mm)

    %{
      "rod_position_low_bits" => Bitwise.band(raw, 0b111),
      "rod_position_middle_bits" => raw |> Bitwise.bsr(3) |> Bitwise.band(0xFF),
      "rod_position_high_bit" => Bitwise.bsr(raw, 11)
    }
  end
end
