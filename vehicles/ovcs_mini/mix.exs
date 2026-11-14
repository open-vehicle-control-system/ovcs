defmodule OvcsMini.MixProject do
  use Mix.Project

  def project do
    [
      app: :ovcs_mini,
      version: "0.1.0",
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      dialyzer: [
        plt_add_apps: [:radio_control_bridge, :ros_bridge, :ovcs_bus_gateway, :vision_core]
      ]
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  # A vehicle is "a set of firmwares": one VMS, the vision unit and the
  # shared bridges image (which runs one instance per entry in
  # `bridge_firmwares/0`). OvcsMini has no infotainment side, so it skips
  # infotainment_firmware. Depending on the firmware projects here gives
  # the composer modules access to `VmsCore.Vehicle`, `VisionCore`,
  # `OvcsBus.Message`, and Cantastic — all pulled in transitively — and
  # makes `./ovcs run ovcs_mini` self-contained against this vehicle's
  # `_build` tree. `simulator_core` holds the simulated components
  # `OvcsMini.Simulator` names, on the targets the `ros` bridge builds
  # it for; the simulator runner runs them, not the vehicle.
  defp deps do
    [
      {:ovcs_vehicle, path: "../../libraries/ovcs_vehicle"},
      {:vms_firmware, path: "../../vms/firmware"},
      {:vision_firmware, path: "../../vision/firmware"},
      {:bridge_firmware, path: "../../bridges/firmware"},
      {:simulator_core,
       path: "../../simulator/core",
       targets: [:host, :ovcs_base_can_system_rpi4, :rpi5],
       runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
  end
end
