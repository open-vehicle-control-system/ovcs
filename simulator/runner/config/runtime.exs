import Config

if config_env() != :test do
  vehicle =
    OvcsVehicle.Firmware.resolve_vehicle(__DIR__, config_env()) ||
      raise "simulator runner: set VEHICLE to the vehicle's module, such as VEHICLE=OvcsMini"

  simulator = SimulatorRunner.Simulator.fetch!(vehicle)
  mapping = System.get_env("CAN_NETWORK_MAPPINGS") || simulator.can_mapping

  config :simulator_runner, :simulator, simulator

  config :cantastic,
    otp_app: vehicle.can_config_otp_app(),
    priv_can_config_path: simulator.can_config_path,
    can_network_mappings: SimulatorRunner.Simulator.can_network_mappings(mapping)
end
