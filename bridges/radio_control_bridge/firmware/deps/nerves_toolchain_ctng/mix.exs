defmodule Nerves.Toolchain.Ctng.MixProject do
  use Mix.Project

  @app :nerves_toolchain_ctng
  @version Path.join(__DIR__, "VERSION")
           |> File.read!()
           |> String.trim()

  def project do
    [
      app: @app,
      version: @version,
      elixir: "~> 1.4",
      nerves_package: [type: :toolchain_platform],
      description: description(),
      package: package(),
      deps: deps()
    ]
  end

  defp deps do
    [{:nerves, "~> 1.0", runtime: false}]
  end

  defp description do
    """
    Nerves Toolchain CTNG - Toolchain Platform
    """
  end

  defp package do
    [
      files: [
        "lib",
        "patches",
        "scripts",
        "build.sh",
        "README.md",
        "LICENSE",
        "mix.exs",
        "VERSION",
        "defaults"
      ],
      licenses: ["Apache-2.0"],
      links: %{"Github" => "https://github.com/nerves-project/toolchains"}
    ]
  end
end
