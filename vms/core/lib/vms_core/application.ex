defmodule VmsCore.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    if Application.get_env(:vms_core, :load_debugger_dependencies) do
      load_debugger_dependencies()
    end

    children = [
      VmsCore.Repo,
      {Ecto.Migrator,
        repos: Application.fetch_env!(:vms_core, :ecto_repos),
        skip: skip_migrations?()},
      {Phoenix.PubSub, name: VmsCore.Bus},

      # Controllers
      {VmsCore.Controllers.Configuration, []},
      %{
        id: VmsCore.Controllers.FrontController,
        start: {
          VmsCore.Controllers.GenericController,
          :start_link, [%{
            process_name: VmsCore.Controllers.FrontController,
            control_digital_pins: true,
            control_other_pins: false
          }]
        }
      },
      %{
        id: VmsCore.Controllers.ControlsController,
        start: {
          VmsCore.Controllers.GenericController,
          :start_link, [%{
            process_name: VmsCore.Controllers.ControlsController,
            control_digital_pins: true,
            control_other_pins: true
          }]
        }
      },
      %{
        id: VmsCore.Controllers.RearController,
        start: {
          VmsCore.Controllers.GenericController,
          :start_link, [%{
            process_name: VmsCore.Controllers.RearController,
            control_digital_pins: true,
            control_other_pins: false
          }]
        }
      },

      # VwPolo
      {VmsCore.VwPolo.Dashboard, %{
        contact_source: VmsCore.VwPolo.IgnitionLock,
        rotation_per_minute_source: VmsCore.NissanLeaf.Em57.Inverter
      }},
      {VmsCore.VwPolo.Abs, %{
        contact_source: VmsCore.VwPolo.IgnitionLock,
        rotation_per_minute_source: VmsCore.NissanLeaf.Em57.Inverter
      }},
      {VmsCore.VwPolo.PassengerCompartment, []},
      {VmsCore.VwPolo.IgnitionLock, []},
      {VmsCore.VwPolo.PowerSteeringPump, %{
        selected_gear_source: VmsCore.GearSelector
      }},

      # NissanLeaf
      {VmsCore.NissanLeaf.Em57.Charger, []},
      {VmsCore.NissanLeaf.Em57.Inverter, %{
        selected_gear_source: VmsCore.GearSelector,
        requested_throttle_source: VmsCore.ThrottlePedal,
        contact_source: VmsCore.VwPolo.IgnitionLock,
        controller: VmsCore.Controllers.FrontController,
        power_relay_pin: 5
      }},

      # Orion
      {VmsCore.Orion.Bms2, []},

      #Bosch
      {VmsCore.Bosch.IboosterGen2, %{
        contact_source: VmsCore.VwPolo.IgnitionLock,
        controller: VmsCore.Controllers.FrontController,
        power_relay_pin: 7
      }},
      {VmsCore.Bosch.Lws, []},

      # OVCS
      {VmsCore.GearSelector, %{
        requested_gear_source: VmsCore.Infotainment,
        ready_to_drive_source: VmsCore.Vehicle.OVCS1,
        speed_source: VmsCore.VwPolo.Abs,
        requested_throttle_source: VmsCore.ThrottlePedal
      }},
      {VmsCore.ThrottlePedal, %{
        controller: VmsCore.Controllers.ControlsController,
        throttle_a_pin: 0,
        throttle_b_pin: 1
      }},
      {VmsCore.PassengerCompartment, %{
        passenger_compartement_source: VmsCore.VwPolo.PassengerCompartment
      }},
      {VmsCore.Infotainment, []},
      {VmsCore.NetworkInterfacesManager, []},
      {VmsCore.Status, []},
      {VmsCore.HighVoltageContactors, %{
        contact_source: VmsCore.VwPolo.IgnitionLock,
        inverter_output_voltage_source: VmsCore.NissanLeaf.Em57.Inverter,
        required_precharge_output_voltage: Decimal.new(300),
        controller: VmsCore.Controllers.RearController,
        main_negative_relay_pin: 5,
        main_positive_relay_pin: 6,
        precharge_relay_pin: 7
      }},

      # Vehicle
      {VmsCore.Vehicles.OVCS1, %{
        contact_source: VmsCore.VwPolo.IgnitionLock
      }}
    ]

    opts = [strategy: :one_for_one, name: VmsCore.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp skip_migrations?() do
    # By default, sqlite migrations are run when using a release
    System.get_env("RELEASE_NAME") != nil
  end

  defp load_debugger_dependencies do
    Mix.ensure_application!(:wx)
    Mix.ensure_application!(:runtime_tools)
    Mix.ensure_application!(:observer)
  end
end
