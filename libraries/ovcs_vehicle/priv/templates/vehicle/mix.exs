defmodule <%= @module %>.MixProject do
  use Mix.Project

  def project do
    [
      app: :<%= @name %>,
      version: "0.1.0",
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    base = [extra_applications: [:logger]]

    # Only run the local-dev Application on host. Firmware builds
    # (MIX_TARGET = Nerves system) use `vms/firmware` /
    # `infotainment/firmware` / `bridges/firmware` instead.
    case Mix.target() do
      :host -> base ++ [mod: {<%= @module %>.Application, []}]
      _ -> base
    end
  end

  defp deps do
    [
      {:ovcs_vehicle, path: "../../libraries/ovcs_vehicle"},
      {:ovcs_can, path: "../../libraries/ovcs_can"},
      {:cantastic, path: "../../libraries/cantastic"},
      {:vms_core, path: "../../vms/core"}<%= if @infotainment do %>,
      {:infotainment_core, path: "../../infotainment/core"}<% end %>
    ] ++ local_dev_deps()
  end

  # Host-only deps pulled in for `cd vehicles/<%= @name %> && iex -S mix`
  # (or `./ovcs run <%= @name %>`). Firmware builds exclude these so the
  # Nerves releases stay lean — no cyclic VMS/infotainment/bridges →
  # vehicle → VMS/infotainment/bridges.
  defp local_dev_deps do
    case Mix.target() do
      :host ->
        [
          {:vms_api, path: "../../vms/api"}<%= if @infotainment do %>,
          {:infotainment_api, path: "../../infotainment/api"}<% end %>
        ] ++ bridge_deps()

      _ ->
        []
    end
  end

  # `bridges/firmware` is the shared Nerves image, not a library —
  # always exclude. Add bridge names here if a lib ever has a dep
  # that can't coexist with Phoenix in one BEAM.
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
