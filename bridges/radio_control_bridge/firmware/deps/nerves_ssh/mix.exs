defmodule NervesSSH.MixProject do
  use Mix.Project

  @version "1.0.0"
  @source_url "https://github.com/nerves-project/nerves_ssh"

  def project do
    [
      app: :nerves_ssh,
      version: @version,
      elixir: "~> 1.13",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: description(),
      dialyzer: dialyzer(),
      docs: docs(),
      package: package(),
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
      extra_applications: [:logger, :public_key, :ssh],
      mod: {NervesSSH.Application, []}
    ]
  end

  defp deps do
    [
      {:dialyxir, "~> 1.4.0", only: :dev, runtime: false},
      {:ex_doc, "~> 0.22", only: :docs, runtime: false},
      {:ssh_subsystem_fwup, "~> 0.5"},
      {:nerves_runtime, "~> 0.11"},
      # lfe currently requires `compile: "make"` to build and this is
      # disallowed when pushing the package to hex.pm.  Work around this by
      # listing it as dev/test only.
      {:lfe, "~> 2.0", only: [:dev, :test], compile: "make", optional: true},
      {:sshex, "~> 2.2.1", only: [:dev, :test]},
      {:credo, "~> 1.2", only: :test, runtime: false}
    ]
  end

  defp description do
    "Manage a SSH daemon and subsystems on Nerves devices"
  end

  defp dialyzer() do
    [
      flags: [:missing_return, :extra_return, :unmatched_returns, :error_handling, :underspecs],
      plt_add_apps: [:lfe]
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

  defp package do
    %{
      files: ["CHANGELOG.md", "lib", "LICENSE", "mix.exs", "README.md"],
      licenses: ["Apache-2.0"],
      links: %{"GitHub" => @source_url}
    }
  end
end
