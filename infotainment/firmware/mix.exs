defmodule OvcsInfotainmentFirmware.MixProject do
  use Mix.Project

  @app :infotainment_firmware
  @version "0.1.0"
  @all_targets [
    :ovcs_base_can_system_rpi5
  ]

  def project do
    [
      app: @app,
      version: @version,
      elixir: "~> 1.17",
      archives: [nerves_bootstrap: "~> 1.13"],
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
      included_applications: [:infotainment_api],
      extra_applications: [:logger, :runtime_tools],
      start_phases: [{:load_and_start_apps, []}]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      # Dependencies for all targets
      {:nerves, "~> 1.10", runtime: false},
      {:shoehorn, "~> 0.9.1"},
      {:ring_logger, "~> 0.11.0"},
      {:toolshed, "~> 0.4.0"},

      # Allow Nerves.Runtime on host to support development, testing and CI.
      # See config/host.exs for usage.
      {:nerves_runtime, "~> 0.13.0"},

      # Dependencies for all targets except :host
      {:nerves_pack, "~> 0.7.1", targets: @all_targets},
      {:vintage_net, "~> 0.13"},
      {:vintage_net_ethernet, "~> 0.11"},
      {:plug_cowboy, "~> 2.0"},
      {:infotainment_api, path: "../api", targets: @all_targets, env: Mix.env(), runtime: false},
      {:nerves_flutter_support, "~> 1.0.0"},

      # Dependencies for specific targets
      # NOTE: It's generally low risk and recommended to follow minor version
      # bumps to Nerves systems. Since these include Linux kernel and Erlang
      # version updates, please review their release notes in case
      # changes to your application are needed.
      {
        :ovcs_base_can_system_rpi5,
        github: "open-vehicle-control-system/ovcs_base_can_system_rpi5",
        runtime: false,
        targets: :ovcs_base_can_system_rpi5,
        nerves: [compile: false],
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
      steps: [&Nerves.Release.init/1, &NervesFlutterSupport.InstallRuntime.run/1, &NervesFlutterSupport.BuildFlutterApp.run/1, :assemble],
      strip_beams: Mix.env() == :prod or [keep: ["Docs"]],
      flutter: [project_dir: Path.expand("../dashboard/")]
    ]
  end
end
