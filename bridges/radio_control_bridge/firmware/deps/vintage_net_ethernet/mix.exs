defmodule VintageNetEthernet.MixProject do
  use Mix.Project

  @version "0.11.2"
  @source_url "https://github.com/nerves-networking/vintage_net_ethernet"

  def project do
    [
      app: :vintage_net_ethernet,
      version: @version,
      elixir: "~> 1.11",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      dialyzer: dialyzer(),
      docs: docs(),
      package: package(),
      description: description(),
      preferred_cli_env: %{
        docs: :docs,
        "hex.publish": :docs,
        "hex.build": :docs,
        credo: :test
      }
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp description do
    "Ethernet networking for VintageNet"
  end

  defp package do
    %{
      files: [
        "CHANGELOG.md",
        "lib",
        "mix.exs",
        "README.md",
        "LICENSE"
      ],
      licenses: ["Apache-2.0"],
      links: %{"GitHub" => @source_url}
    }
  end

  defp deps do
    [
      {:vintage_net, "~> 0.12.0 or ~> 0.13.0"},
      {:credo, "~> 1.2", only: :test, runtime: false},
      {:dialyxir, "~> 1.1", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.22", only: :docs, runtime: false}
    ]
  end

  defp dialyzer() do
    [
      flags: [:missing_return, :extra_return, :unmatched_returns, :error_handling, :underspecs]
    ]
  end

  defp docs do
    [
      extras: ["README.md", "CHANGELOG.md"],
      main: "readme",
      source_ref: "v#{@version}",
      source_url: @source_url,
      skip_undefined_reference_warnings_on: ["CHANGELOG.md"]
    ]
  end
end
