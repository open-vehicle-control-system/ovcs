defmodule OvcsInfotainmentFirmware.MixProject do
  use Mix.Project

  @app :infotainment_firmware
  @version "0.1.0"
  @all_targets [
    :rpi4, :ovcs_infotainment_system_rpi4
  ]

  def project do
    [
      app: @app,
      version: @version,
      elixir: "~> 1.11",
      archives: [nerves_bootstrap: "~> 1.12"],
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      releases: [{@app, release()}],
      preferred_cli_target: [run: :host, test: :host]
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      mod: {InfotainmentFirmware.Application, []},
      extra_applications: [:logger, :runtime_tools]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      # Dependencies for all targets
      {:nerves, "~> 1.10", runtime: false},
      {:shoehorn, "~> 0.9.1"},
      {:ring_logger, "~> 0.10.0"},
      {:toolshed, "~> 0.3.0"},

      # Allow Nerves.Runtime on host to support development, testing and CI.
      # See config/host.exs for usage.
      {:nerves_runtime, "~> 0.13.0"},

      # Dependencies for all targets except :host
      {:nerves_pack, "~> 0.7.0", targets: @all_targets},
      {:vintage_net_wifi, "~> 0.11.7", targets: @all_targets},
      {:plug_cowboy, "~> 2.0"},
      {:nerves_cog, github: "coop/nerves_cog"},
      {:nerves_weston, github: "Spin42/nerves_weston"},
      {:infotainment_api, path: "../infotainment_api", targets: @all_targets, env: Mix.env()},

      # Dependencies for specific targets
      # NOTE: It's generally low risk and recommended to follow minor version
      # bumps to Nerves systems. Since these include Linux kernel and Erlang
      # version updates, please review their release notes in case
      # changes to your application are needed.
      {
        :ovcs_infotainment_system_rpi4,
        path: "../../ovcs_infotainment_system_rpi4",
        runtime: false,
        targets: :ovcs_infotainment_system_rpi4,
        nerves: [compile: true]
      },
    ]
  end

  def release do
    [
      overwrite: true,
      # Erlang distribution is not started automatically.
      # See https://hexdocs.pm/nerves_pack/readme.html#erlang-distribution
      cookie: "#{@app}_cookie",
      include_erts: &Nerves.Release.erts/0,
      steps: [&Nerves.Release.init/1, :assemble],
      strip_beams: Mix.env() == :prod or [keep: ["Docs"]]
    ]
  end
end