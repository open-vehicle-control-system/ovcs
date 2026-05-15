defmodule OvcsMini.MixProject do
  use Mix.Project

  def project do
    [
      app: :ovcs_mini,
      version: "0.1.0",
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  # A vehicle is "a set of firmwares": one VMS and the shared bridges
  # image (which runs one instance per entry in `bridge_firmwares/0`).
  # OvcsMini has no infotainment side, so it skips infotainment_firmware.
  # Depending on the firmware projects here gives the composer modules
  # access to `VmsCore.Vehicle`, `OvcsBus.Message`, and Cantastic —
  # all pulled in transitively — and makes `./ovcs run ovcs_mini`
  # self-contained against this vehicle's `_build` tree.
  defp deps do
    [
      {:ovcs_vehicle, path: "../../libraries/ovcs_vehicle"},
      {:vms_firmware, path: "../../vms/firmware"},
      {:bridge_firmware, path: "../../bridges/firmware"},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false}
    ]
  end
end
