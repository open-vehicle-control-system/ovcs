defmodule Obd2.MixProject do
  use Mix.Project

  def project do
    [
      app: :obd2,
      version: "0.1.0",
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  # A vehicle is "a set of firmwares": one VMS and one infotainment.
  # Obd2 declares no bridge_firmwares/0, so it skips bridge_firmware.
  # Depending on the firmware projects here gives the composer modules
  # access to `VmsCore.Vehicle`, `InfotainmentCore.Vehicle`,
  # `OvcsBus.Message`, and Cantastic — all pulled in transitively —
  # and makes `./ovcs run obd2` self-contained against this vehicle's
  # `_build` tree.
  defp deps do
    [
      {:ovcs_vehicle, path: "../../libraries/ovcs_vehicle"},
      {:vms_firmware, path: "../../vms/firmware"},
      {:infotainment_firmware, path: "../../infotainment/firmware"},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false}
    ]
  end
end
