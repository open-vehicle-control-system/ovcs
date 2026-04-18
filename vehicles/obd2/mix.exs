defmodule Obd2.MixProject do
  use Mix.Project

  def project do
    [
      app: :obd2,
      version: "0.1.0",
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    base = [extra_applications: [:logger]]

    case Mix.target() do
      :host -> base ++ [mod: {Obd2.Application, []}]
      _ -> base
    end
  end

  defp deps do
    [
      {:ovcs_vehicle, path: "../../libraries/ovcs_vehicle"},
      {:ovcs_can, path: "../../libraries/ovcs_can"},
      {:cantastic, path: "../../libraries/cantastic"},
      {:vms_core, path: "../../vms/core"},
      {:infotainment_core, path: "../../infotainment/core"},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false}
    ] ++ local_dev_deps()
  end

  # Host-only deps: both API Phoenix endpoints + every bridge lib
  # under bridges/*. OBD2 has no bridges today but will transparently
  # pick them up via the dir-scan if any are added later.
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
