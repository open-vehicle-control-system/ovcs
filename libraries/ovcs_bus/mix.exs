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
      # Tortoise311: pure-Elixir MQTT 3.1.1 client, no native deps.
      # Chosen over emqtt because quicer (emqtt's QUIC NIF) doesn't
      # cross-compile on Nerves toolchains.
      {:tortoise311, "~> 0.12"},
      # MuonTrap: supervised OS processes. Used by OvcsBus.Broker to
      # host a Mosquitto daemon. Cross-compiles fine on Nerves.
      {:muontrap, "~> 1.0"},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false}
    ]
  end
end
