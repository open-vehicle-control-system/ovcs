defmodule RadioControlBridge.MixProject do
  use Mix.Project

  def project do
    [
      app: :radio_control_bridge,
      version: "0.1.0",
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  defp deps do
    [
      {:ovcs_bridge, path: "../../libraries/ovcs_bridge"},
      {:cantastic, path: "../../libraries/cantastic"},
      {:express_lrs, path: "../../libraries/express_lrs"},
      {:msp_osd, path: "../../libraries/msp_osd"}
    ]
  end
end
