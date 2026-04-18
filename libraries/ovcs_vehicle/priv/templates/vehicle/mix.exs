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

  # Only the libraries the composer modules themselves compile against:
  # the OvcsVehicle behaviour, the shared CAN YAMLs, Cantastic macros,
  # OvcsBus.Message, and the VMS/infotainment core behaviours. No api,
  # no firmware, no bridge libs — those are pulled in by each firmware
  # project and reach the vehicle via the runtime code-path prepend.
  defp deps do
    [
      {:ovcs_vehicle, path: "../../libraries/ovcs_vehicle"},
      {:ovcs_can, path: "../../libraries/ovcs_can"},
      {:cantastic, path: "../../libraries/cantastic"},
      {:ovcs_bus, path: "../../libraries/ovcs_bus"},
      {:vms_core, path: "../../vms/core"}<%= if @infotainment do %>,
      {:infotainment_core, path: "../../infotainment/core"}<% end %>
    ]
  end
end
