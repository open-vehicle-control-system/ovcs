defmodule CRC.Mixfile do
  use Mix.Project

  @source_url "https://github.com/TattdCodeMonkey/crc"
  @version "0.10.5"

  def project() do
    [
      app: :crc,
      version: @version,
      elixir: ">= 1.4.2 and < 2.0.0",
      elixirc_paths: elixirc_paths(Mix.env()),
      build_embedded: Mix.env() == :prod,
      start_permanent: Mix.env() == :prod,
      compilers: [:elixir_make] ++ Mix.compilers(),
      make_env: %{"MIX_ENV" => to_string(Mix.env())},
      make_clean: ["clean"],
      make_cwd: "c_src",
      name: "crc",
      package: package(),
      deps: deps(),
      docs: docs()
    ]
  end

  def application() do
    [
      extra_applications: []
    ]
  end

  defp deps() do
    [
      {:elixir_make, "~> 0.6", runtime: false},
      {:ex_doc, ">= 0.0.0", only: :dev, runtime: false},
      {:propcheck, "~> 1.0", only: :test}
    ]
  end

  # Specifies which paths to compile per environment
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp package() do
    [
      name: :crc,
      description: "A library used to calculate CRC checksums for binary data.",
      files: [
        "c_src/nif/*.c",
        "c_src/nif/*.h",
        "c_src/Makefile",
        "c_src/Makefile.win",
        "lib",
        "LICENSE*",
        "mix.exs",
        "README*",
        "rebar.config",
        "src"
      ],
      maintainers: ["Rodney Norris"],
      licenses: ["MIT"],
      links: %{
        "Changelog" => "https://hexdocs.pm/crc/changelog.html",
        "GitHub" => @source_url
      }
    ]
  end

  defp docs do
    [
      extras: [
        "CHANGELOG.md",
        "LICENSE.md": [title: "License"],
        "README.md": [title: "Overview"]
      ],
      main: "readme",
      source_url: @source_url,
      source_ref: "v#{@version}",
      api_reference: false,
      formatters: ["html"]
    ]
  end
end
