defmodule OvcsDrivers.MixProject do
  use Mix.Project

  def project do
    [
      app: :ovcs_drivers,
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
      # Each driver pulls in only the buses it actually uses. Today
      # everything is I²C; add `:circuits_gpio` / `:circuits_spi`
      # alongside if a SPI / GPIO driver lands here.
      {:circuits_i2c, "~> 2.0"},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false}
    ]
  end
end
