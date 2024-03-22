defmodule VmsApiWeb.Api.InverterStateJSON do
  use VmsApiWeb, :view
  alias Decimal, as: D

  def render("inverter_state.json", %{inverter_state: inverter_state}) do
    %{
      type: "inverterState",
      id:    "inverterState",
      attributes: %{
        rotationPerMinute: D.abs(inverter_state.rotation_per_minute),
        requestedTorque: inverter_state.requested_torque,
        effectiveTorque: inverter_state.effective_torque,
        outputVoltage: inverter_state.output_voltage,
        inverterCommunicationBoardTemperature: inverter_state.inverter_communication_board_temperature,
        insulatedGateBipolarTransistorTemperature: inverter_state.insulated_gate_bipolar_transistor_temperature,
        insulatedGateBipolarTransistorBoardTemperature: inverter_state.insulated_gate_bipolar_transistor_board_temperature,
        motorTemperature: inverter_state.motor_temperature
      }
    }
  end
end
