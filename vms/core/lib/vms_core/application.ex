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
      {VmsCore.VwPolo.Dashboard, []},
      {VmsCore.GearSelector, %{
        requested_gear_source: VmsCore.Infotainment,
        ready_to_drive_source: VmsCore.Vehicle.OVCS1,
        speed_source: VmsCore.VwPolo.Abs,
        requested_throttle_source: VmsCore.ThrottlePedal
      }},
      %{
        id: VmsCore.Controllers.ControlsController,
        start: {
          VmsCore.Controllers.GenericController,
          :start_link, [%{process_name:  VmsCore.Controllers.ControlsController, control_digital_pins: true, control_other_pins: true}]
        }
      },
      {VmsCore.ThrottlePedal, %{
        controller: VmsCore.Controllers.ControlsController,
        throttle_a_pin: 0,
        throttle_b_pin: 1
      }},
      {VmsCore.VwPolo.Abs, []},
      {VmsCore.VwPolo.PassengerCompartment, []},
      {VmsCore.VwPolo.IgnitionLock, []},
      {VmsCore.NissanLeaf.Em57.Charger, []},
      {VmsCore.Orion.Bms2, []},
      {VmsCore.NissanLeaf.Em57.Inverter, %{
        selected_gear_source: VmsCore.GearSelector,
        requested_throttle_source: VmsCore.ThrottlePedal
      }},
      {VmsCore.BatteryManagementSystem, []},
      {VmsCore.Charger, []},
      {VmsCore.PassengerCompartment, []},
      {VmsCore.Inverter, []},
      {VmsCore.Vehicle, []},
      {VmsCore.NetworkInterfacesManager, []},
      {VmsCore.Status, []},
      {VmsCore.Infotainment, []},
      {VmsCore.Bosch.IboosterGen2, []},
      {VmsCore.Controllers.Configuration, []},
      {VmsCore.Controllers.FrontController, []},
      {VmsCore.Controllers.RearController, []},
      {VmsCore.VwPolo.PowerSteeringPump, []},
      {VmsCore.Bosch.Lws, []},
      {VmsCore.BrakingSystem, []},
      {VmsCore.SteeringColumn, []}
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
