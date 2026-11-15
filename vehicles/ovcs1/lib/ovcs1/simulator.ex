defmodule Ovcs1.Simulator do
  @moduledoc """
  OVCS1's simulated hardware, `Ovcs1.simulator/0`: the parts the VMS
  drives, on the controllers, pins, networks and radio channels of
  `Ovcs1.Vms.Composer.wiring/0`. Only the physical parameters are set
  here. The vehicle's README lists them and which are estimates.

  The key turns to start once the VMS is up, then back to on, so OVCS1
  reaches ready to drive with no manual step. The radio stays at
  `:manual`.
  """

  alias Ovcs1.Vms.Composer
  alias SimulatorCore.SimulatedComponents, as: Simulated

  @simulated_networks ~w(ovcs misc leaf_drive polo_drive)

  @vehicle %{wheelbase_m: 2.46, wheel_radius_m: 0.289, max_speed_m_s: 25.0}

  @mass_kg 1_300.0
  @pack_voltage_v 360
  # The Leaf motor drives the Polo's 02R gearbox through a coupling, with no Leaf reducer.
  @polo_02r_first_gear_ratio 3.300
  @polo_02r_final_drive_ratio 3.389
  @steering_ratio 17.0
  @steps_per_column_degree 100
  @column_limit_deg 520
  @ibooster_rod_speed_mm_s 100.0
  @ibooster_full_travel_deceleration_m_s2 8.0

  @key_steps [{1_000, :start}, {2_000, :on}]
  @radio_centre_us 1500
  @radio_manual_us 1000
  @radio_forward_us 1000

  @doc "`t:OvcsVehicle.simulator/0` for OVCS1."
  @spec simulator() :: OvcsVehicle.simulator()
  def simulator do
    %{
      can_config_path: "can/simulator.yml",
      can_mapping: can_mapping(),
      vehicle: @vehicle,
      simulated_components: generic_controllers() ++ parts()
    }
  end

  defp generic_controllers do
    for controller <- Map.keys(Composer.generic_controllers()),
        do: {Simulated.OVCS.GenericController, name: frame_prefix(controller)}
  end

  defp parts do
    %{
      inverter: inverter,
      high_voltage_contactors: contactors,
      ibooster: ibooster,
      steering_column: column
    } = wiring = Composer.wiring()

    [
      {Simulated.Volkswagen.Polo9N.ABS, network: wiring.abs.network},
      {Simulated.Volkswagen.Polo9N.IgnitionLock,
       network: wiring.ignition_lock.network, steps: @key_steps},
      {Simulated.Nissan.LeafAZE0.Inverter,
       network: inverter.network,
       controller: frame_prefix(inverter.controller),
       power_relay_pin: inverter.power_relay_pin,
       main_negative_relay_pin: contactors.main_negative_relay_pin,
       main_positive_relay_pin: contactors.main_positive_relay_pin,
       precharge_relay_pin: contactors.precharge_relay_pin,
       pack_voltage_v: @pack_voltage_v,
       reduction_ratio: @polo_02r_first_gear_ratio * @polo_02r_final_drive_ratio,
       mass_kg: @mass_kg},
      {Simulated.Bosch.IBoosterGen2,
       network: ibooster.network,
       controller: frame_prefix(ibooster.controller),
       power_relay_pin: ibooster.power_relay_pin,
       rod_speed_mm_s: @ibooster_rod_speed_mm_s,
       full_travel_deceleration_m_s2: @ibooster_full_travel_deceleration_m_s2},
      {Simulated.OVCS.SteeringColumn,
       network: column.network,
       power_relay_controller: frame_prefix(column.power_relay_controller),
       power_relay_pin: column.power_relay_pin,
       actuation_controller: frame_prefix(column.actuation_controller),
       direction_pin: column.direction_pin,
       external_pwm_id: column.external_pwm_id,
       steps_per_column_degree: @steps_per_column_degree,
       steering_ratio: @steering_ratio,
       column_limit_deg: @column_limit_deg},
      {Simulated.OVCS.RadioControl, channels: radio_channels(wiring.radio_control_channels)}
    ]
  end

  defp radio_channels(channels) do
    %{
      channels.steering => @radio_centre_us,
      channels.throttle => @radio_centre_us,
      channels.requested_control_level => @radio_manual_us,
      channels.direction => @radio_forward_us
    }
  end

  # The VMS's host mapping, limited to the networks the simulated hardware uses.
  defp can_mapping do
    for pair <- String.split(Composer.default_can_mapping(:host), ","),
        [network, _interface] = String.split(pair, ":"),
        network in @simulated_networks do
      pair
    end
    |> Enum.join(",")
  end

  # A generic controller's frames are named after its VMS process.
  defp frame_prefix(controller),
    do: controller |> Module.split() |> List.last() |> Macro.underscore()
end
