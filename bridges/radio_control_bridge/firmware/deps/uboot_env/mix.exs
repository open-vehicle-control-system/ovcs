defmodule UBootEnv.MixProject do
  use Mix.Project

  @version "1.0.1"
  @source_url "https://github.com/nerves-project/uboot_env"

  if String.to_integer(System.otp_release()) < 21 do
    Mix.raise("OTP 21 or later required. Found OTP #{System.otp_release()}.")
  end

  def project do
    [
      app: :uboot_env,
      version: @version,
      elixir: "~> 1.7",
      start_permanent: Mix.env() == :prod,
      description: description(),
      package: package(),
      docs: docs(),
      deps: deps(),
      dialyzer: [
        plt_add_apps: [:mix],
        flags: [:unmatched_returns, :error_handling, :missing_return, :extra_return]
      ],
      preferred_cli_env: %{docs: :docs, "hex.build": :docs, "hex.publish": :docs, credo: :test}
    ]
  end

  def application do
    []
  end

  defp deps do
    [
      {:ex_doc, "~> 0.22", only: :docs, runtime: false},
      {:dialyxir, "~> 1.1", only: :dev, runtime: false},
      {:credo, "~> 1.2", only: :test, runtime: false}
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

  defp description do
    "Read and write to U-Boot environment blocks"
  end

  defp package do
    [
      licenses: ["Apache-2.0"],
      links: %{"GitHub" => @source_url}
    ]
  end
end
