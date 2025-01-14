defmodule Fss.MixProject do
  use Mix.Project

  @version "0.1.1"
  @github_url "https://github.com/elixir-explorer/fss"

  def project do
    [
      app: :fss,
      version: @version,
      elixir: "~> 1.14",
      start_permanent: Mix.env() == :prod,
      package: package(),
      docs: docs(),
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      # docs
      {:ex_doc, "~> 0.30", only: :docs, runtime: false}
    ]
  end

  defp docs do
    [main: "FSS", source_ref: "v#{@version}", source_url: @github_url]
  end

  defp package do
    [
      name: "fss",
      description: "An abstraction to describe files on local or remote file systems",
      files: ~w(README* LICENSE* mix.exs lib),
      licenses: ["Apache-2.0"],
      links: %{"GitHub" => @github_url}
    ]
  end
end
