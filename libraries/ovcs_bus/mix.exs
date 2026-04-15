defmodule OvcsBus.MixProject do
  use Mix.Project

  def project do
    [
      app: :ovcs_bus,
      version: "0.1.0",
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {OvcsBus.Application, []}
    ]
  end

  defp deps do
    [
      {:phoenix_pubsub, "~> 2.1"},
      {:emqtt, "~> 1.10"},
      {:muontrap, "~> 1.0"}
    ]
  end
end
