defmodule CircularBuffer.MixProject do
  use Mix.Project

  @version "0.4.1"

  def project do
    [
      app: :circular_buffer,
      version: @version,
      elixir: "~> 1.8",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: description(),
      package: package(),
      name: "CircularBuffer",
      source_url: "https://github.com/keathley/circular_buffer",
      docs: docs(),
      dialyzer: dialyzer()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    []
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:propcheck, "~> 1.2", only: [:dev, :test]},
      {:credo, "~> 1.5", only: [:dev, :test]},
      {:ex_doc, "~> 0.19", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.1.0", only: [:dev, :test], runtime: false}
    ]
  end

  def description do
    """
    General purpose circular buffer.
    """
  end

  def package do
    [
      name: "circular_buffer",
      licenses: ["MIT"],
      links: %{"GitHub" => "https://github.com/keathley/circular_buffer"}
    ]
  end

  def docs do
    [
      source_ref: "v#{@version}",
      source_url: "https://github.com/keathley/circular_buffer",
      main: "CircularBuffer"
    ]
  end

  defp dialyzer() do
    [
      flags: [:race_conditions, :unmatched_returns, :error_handling]
    ]
  end
end
