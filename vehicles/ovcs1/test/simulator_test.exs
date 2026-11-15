defmodule Ovcs1.SimulatorTest do
  @moduledoc """
  OVCS1's simulated hardware is wired as the VMS composer wires the real
  parts: same controllers, pins and networks.
  """
  use ExUnit.Case, async: true

  alias SimulatorCore.SimulatedComponents.Bosch.IBoosterGen2
  alias SimulatorCore.SimulatedComponents.Nissan.LeafAZE0.Inverter
  alias SimulatorCore.SimulatedComponents.OVCS.{GenericController, SteeringColumn}
  alias SimulatorCore.SimulatedComponents.Volkswagen.Polo9N.{ABS, IgnitionLock}
  alias VmsCore.Components.{Bosch, Nissan, OVCS, Volkswagen}

  defp simulated(module) do
    for {^module, opts} <- Ovcs1.simulator().simulated_components, do: Map.new(opts)
  end

  defp vms(module) do
    [opts] = for {^module, opts} <- Ovcs1.Vms.Composer.children(), do: opts
    opts
  end

  defp frame_prefix(controller),
    do: controller |> Module.split() |> List.last() |> Macro.underscore()

  test "simulates each generic controller the VMS starts" do
    vms_controllers =
      for %{start: {OVCS.GenericController, :start_link, [%{process_name: name}]}} <-
            Ovcs1.Vms.Composer.children(),
          do: frame_prefix(name)

    assert Enum.sort(Enum.map(simulated(GenericController), & &1.name)) ==
             Enum.sort(vms_controllers)
  end

  test "the inverter's relays are the pins the VMS's inverter and contactors switch" do
    [inverter] = simulated(Inverter)
    vms_inverter = vms(Nissan.LeafAZE0.Inverter)
    contactors = vms(OVCS.HighVoltageContactors)

    assert inverter.network == vms_inverter.network
    assert inverter.controller == frame_prefix(vms_inverter.controller)
    assert inverter.controller == frame_prefix(contactors.controller)
    assert inverter.power_relay_pin == vms_inverter.power_relay_pin
    assert inverter.main_negative_relay_pin == contactors.main_negative_relay_pin
    assert inverter.main_positive_relay_pin == contactors.main_positive_relay_pin
    assert inverter.precharge_relay_pin == contactors.precharge_relay_pin
  end

  test "the iBooster's power relay is the pin the VMS switches" do
    [ibooster] = simulated(IBoosterGen2)
    vms_ibooster = vms(Bosch.IBoosterGen2)

    assert ibooster.network == vms_ibooster.network
    assert ibooster.controller == frame_prefix(vms_ibooster.controller)
    assert ibooster.power_relay_pin == vms_ibooster.power_relay_pin
  end

  test "the steering column follows the relay, direction pin and PWM the VMS drives" do
    [column] = simulated(SteeringColumn)
    vms_column = vms(OVCS.SteeringColumn)

    assert column.network == vms_column.network
    assert column.power_relay_controller == frame_prefix(vms_column.power_relay_controller)
    assert column.power_relay_pin == vms_column.power_relay_pin
    assert column.actuation_controller == frame_prefix(vms_column.actuation_controller)
    assert column.direction_pin == vms_column.direction_pin
    assert column.external_pwm_id == vms_column.external_pwm_id
  end

  test "the ABS and the ignition lock sit on the networks the VMS reads them on" do
    assert [%{network: abs_network}] = simulated(ABS)
    assert [%{network: lock_network}] = simulated(IgnitionLock)
    assert abs_network == vms(Volkswagen.Polo9N.ABS).network
    assert lock_network == vms(Volkswagen.Polo9N.IgnitionLock).network
  end
end
