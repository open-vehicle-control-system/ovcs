defmodule Ovcs1.MixProject do
  use Mix.Project

  def project do
    [
      app: :ovcs1,
      version: "0.1.0",
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    base = [extra_applications: [:logger]]

    # Only run Ovcs1.Application in local-dev (host target).
    # Firmware builds (MIX_TARGET = Nerves system) must not boot a
    # vehicle-level Application — each side firmware owns its own
    # supervision tree.
    case Mix.target() do
      :host -> base ++ [mod: {Ovcs1.Application, []}]
      _ -> base
    end
  end

  defp deps do
    [
      {:ovcs_vehicle, path: "../../libraries/ovcs_vehicle"},
      {:ovcs_can, path: "../../libraries/ovcs_can"},
      {:cantastic, path: "../../libraries/cantastic"},
      {:vms_core, path: "../../vms/core"},
      {:infotainment_core, path: "../../infotainment/core"}
    ] ++ local_dev_deps()
  end

  # Deps pulled in **only** when the vehicle package is run locally
  # as its own app (`Mix.target() == :host`). Firmware builds set
  # MIX_TARGET to a Nerves system (e.g. `:ovcs_base_can_system_rpi4`)
  # which excludes these — keeps VMS/infotainment/bridges firmware
  # releases from cyclically pulling the full stack back through the
  # vehicle package.
  #
  # Bridge libs are discovered dynamically by walking
  # `bridges/*/mix.exs` so a new bridge dropped into the repo is
  # picked up without touching this file. Having the code in the
  # BEAM doesn't auto-run anything — a supervisor still has to
  # call `<BridgeModule>.children()` to start them.
  defp local_dev_deps do
    case Mix.target() do
      :host ->
        [
          {:vms_api, path: "../../vms/api"},
          {:infotainment_api, path: "../../infotainment/api"}
        ] ++ bridge_deps()

      _ ->
        []
    end
  end

  # Bridges to exclude from the local-dev BEAM. `firmware/` is the
  # shared Nerves project, not a bridge library — always skip.
  # Add more names here if a bridge ever has a dep that can't
  # coexist with Phoenix.
  @host_excluded_bridges ~w(firmware)

  defp bridge_deps do
    "../../bridges/*/mix.exs"
    |> Path.expand(__DIR__)
    |> Path.wildcard()
    |> Enum.map(&Path.dirname/1)
    |> Enum.reject(&(Path.basename(&1) in @host_excluded_bridges))
    |> Enum.map(fn dir ->
      app = dir |> Path.basename() |> String.to_atom()
      {app, path: dir}
    end)
  end
end
