defmodule SimulatorCore.SimulatedComponents.Nissan.LeafAZE0.Inverter do
  @moduledoc """
  A Nissan Leaf AZE0 inverter and its motor, the inverse of
  `VmsCore.Components.Nissan.LeafAZE0.Inverter`: it reads the VMS's
  `vms_torque_request` and reports `inverter_status` and
  `inverter_temperatures`.

  It reads its relays on a generic controller's digital pin request, as
  `VmsCore.Components.OVCS.HighVoltageContactors` switches them:

    * its output voltage is `:pack_voltage_v` while the main negative
      relay and either the precharge or the main positive relay are
      requested, and zero otherwise;
    * while its power relay is requested and it has that voltage, it
      applies the requested torque, through `:reduction_ratio` to the
      wheels, as an acceleration of `:mass_kg`, and reports it as its
      effective torque.

  The motor's rotation is the measured wheel speed through the reduction
  ratio, signed by the direction of travel. Its temperatures read a
  constant 77 °F.

  ## Options

    * `:network` (required) — the inverter's network.
    * `:controller` (required) — the frame-name prefix of the generic
      controller switching its relays, e.g. `"rear_controller"`.
    * `:controller_network` (`:ovcs`).
    * `:power_relay_pin`, `:main_negative_relay_pin`,
      `:main_positive_relay_pin`, `:precharge_relay_pin` (required) —
      that controller's digital pins.
    * `:pack_voltage_v`, `:reduction_ratio`, `:mass_kg` (required).
  """
  @behaviour SimulatorCore.SimulatedComponent

  import SimulatorCore.SimulatedComponent, only: [decimal: 2, float: 2]

  @temperatures %{
    "inverter_communication_board_temperature" => 77,
    "insulated_gate_bipolar_transistor_temperature" => 77,
    "insulated_gate_bipolar_transistor_board_temperature" => 77,
    "motor_temperature" => 77
  }
  @relay_pin_options %{
    power: :power_relay_pin,
    main_negative: :main_negative_relay_pin,
    main_positive: :main_positive_relay_pin,
    precharge: :precharge_relay_pin
  }

  @impl SimulatorCore.SimulatedComponent
  def init(opts) do
    opts = Map.new(opts)

    state = %{
      network: Map.fetch!(opts, :network),
      pin_request: "#{Map.fetch!(opts, :controller)}_digital_pin_request",
      controller_network: Map.get(opts, :controller_network, :ovcs),
      relay_signals:
        Map.new(@relay_pin_options, fn {relay, option} ->
          {relay, "digital_pin#{Map.fetch!(opts, option)}_enabled"}
        end),
      closed_relays: MapSet.new(),
      pack_voltage_v: Map.fetch!(opts, :pack_voltage_v),
      reduction_ratio: Map.fetch!(opts, :reduction_ratio),
      mass_kg: Map.fetch!(opts, :mass_kg),
      requested_torque_nm: 0.0
    }

    received = [
      {state.network, "vms_torque_request"},
      {state.controller_network, state.pin_request}
    ]

    emitted = [
      {state.network, "inverter_status", inverter_status(state, 0)},
      {state.network, "inverter_temperatures", @temperatures}
    ]

    {state, received, emitted}
  end

  @impl SimulatorCore.SimulatedComponent
  def handle_frame("vms_torque_request", signals, state, _now_ms),
    do: %{state | requested_torque_nm: float(signals, "requested_torque")}

  def handle_frame(name, signals, %{pin_request: name} = state, _now_ms) do
    closed_relays =
      for {relay, signal} <- state.relay_signals,
          match?(%{^signal => %{value: true}}, signals),
          into: MapSet.new(),
          do: relay

    %{state | closed_relays: closed_relays}
  end

  @impl SimulatorCore.SimulatedComponent
  def actuations(state, vehicle, _now_ms) do
    if driving?(state) do
      wheel_force_n = state.requested_torque_nm * state.reduction_ratio / vehicle.wheel_radius_m
      [{:acceleration, wheel_force_n / state.mass_kg}]
    else
      []
    end
  end

  @impl SimulatorCore.SimulatedComponent
  def report(state, vehicle, _now_ms) do
    wheel_rpm = vehicle.measured_speed_m_s / (2 * :math.pi() * vehicle.wheel_radius_m) * 60
    motor_rpm = round(wheel_rpm * state.reduction_ratio)
    {state, [{state.network, "inverter_status", inverter_status(state, motor_rpm)}]}
  end

  defp inverter_status(state, motor_rpm) do
    %{
      "inverter_output_voltage" => if(high_voltage?(state), do: state.pack_voltage_v, else: 0),
      "effective_torque" => decimal(effective_torque_nm(state), 1),
      "rotations_per_minute" => motor_rpm
    }
  end

  defp effective_torque_nm(state),
    do: if(driving?(state), do: state.requested_torque_nm, else: 0.0)

  defp driving?(state), do: closed?(state, :power) and high_voltage?(state)

  defp high_voltage?(state),
    do:
      closed?(state, :main_negative) and
        (closed?(state, :precharge) or closed?(state, :main_positive))

  defp closed?(state, relay), do: MapSet.member?(state.closed_relays, relay)
end
