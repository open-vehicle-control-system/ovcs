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

  # No OTP app: each firmware loads this package's ebin at boot.
  def application do
    [extra_applications: [:logger]]
  end

  # The firmwares bring the cores, OvcsBus and Cantastic; no firmware depends on ovcs_vehicle.
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
