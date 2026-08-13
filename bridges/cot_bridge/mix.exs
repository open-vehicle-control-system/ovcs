defmodule CotBridge.MixProject do
  use Mix.Project

  def project do
    [
      app: :cot_bridge,
      version: "0.1.0",
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    # :ssl is only exercised when a vehicle configures `protocol: :tls`,
    # but it must be started unconditionally so the option is a pure
    # config change.
    [extra_applications: [:logger, :ssl]]
  end

  defp deps do
    [
      {:ovcs_bridge, path: "../../libraries/ovcs_bridge"},
      {:decimal, "~> 2.1.1"},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false}
    ]
  end
end
