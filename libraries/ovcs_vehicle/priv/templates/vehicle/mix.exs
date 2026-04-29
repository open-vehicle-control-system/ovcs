defmodule <%= @module %>.MixProject do
  use Mix.Project

  def project do
    [
      app: :<%= @name %>,
      version: "0.1.0",
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  # The vehicle package is metadata + composers only — no runnable
  # OTP app. Every firmware BEAM (vms, infotainment, each bridge)
  # loads the compiled ebin via `Code.prepend_path` at boot and calls
  # into the composer modules directly.
  def application do
    [extra_applications: [:logger]]
  end

  # A vehicle is "a set of firmwares": one VMS, one infotainment, and
  # the shared bridges image (which runs one instance per entry in
  # `bridge_firmwares/0`). Depending on the firmware projects here is
  # what gives the composer modules access to `VmsCore.Vehicle`,
  # `InfotainmentCore.Vehicle`, `OvcsBus.Message`, and Cantastic — all
  # pulled in transitively — and makes `./ovcs run <%= @name %>`
  # self-contained against this vehicle's `_build` tree. `ovcs_vehicle`
  # supplies the top-level `OvcsVehicle` behaviour and doesn't sit in
  # any firmware dep tree, so it stays explicit.
  defp deps do
    [
      {:ovcs_vehicle, path: "../../libraries/ovcs_vehicle"},
      {:vms_firmware, path: "../../vms/firmware"}<%= if @infotainment do %>,
      {:infotainment_firmware, path: "../../infotainment/firmware"}<% end %><%= if @bridges do %>,
      {:bridge_firmware, path: "../../bridges/firmware"}<% end %>,
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false}
    ]
  end
end
