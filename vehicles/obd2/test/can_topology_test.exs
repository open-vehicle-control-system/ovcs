defmodule Obd2.CanTopologyTest do
  @moduledoc """
  Each firmware's CAN topology loads through Cantastic as it does at boot:
  every frame is checked in the direction the topology uses it, and a frame
  Cantastic rejects stops that firmware.
  """
  use ExUnit.Case, async: false

  alias Cantastic.{ConfigurationStore, Interface}

  @cantastic_env [:otp_app, :priv_can_config_path, :can_network_mappings]

  setup do
    previous = Map.new(@cantastic_env, &{&1, Application.fetch_env(:cantastic, &1)})

    on_exit(fn ->
      Enum.each(previous, fn
        {key, {:ok, value}} -> Application.put_env(:cantastic, key, value)
        {key, :error} -> Application.delete_env(:cantastic, key)
      end)
    end)
  end

  for composer <- [Obd2.Vms.Composer, Obd2.Infotainment.Composer] do
    test "#{inspect(composer)} topology loads" do
      assert [_ | _] = load_topology(:obd2, unquote(composer).can_config_path())
    end
  end

  defp load_topology(otp_app, path) do
    Application.put_env(:cantastic, :otp_app, otp_app)
    Application.put_env(:cantastic, :priv_can_config_path, path)
    Application.put_env(:cantastic, :can_network_mappings, network_mappings(otp_app, path))
    start_supervised!(ConfigurationStore)

    interfaces =
      for network <- ConfigurationStore.networks() do
        network |> Map.take([:network_name, :network_config, :interface]) |> Map.put(:socket, nil)
      end

    Interface.configure_receivers_and_watchers(interfaces) ++
      Interface.configure_emitters(interfaces) ++
      Interface.configure_obd2_requests(interfaces)
  end

  defp network_mappings(otp_app, path) do
    {:ok, %{"can_networks" => networks}} =
      otp_app |> :code.priv_dir() |> Path.join(path) |> YamlElixir.read_from_file()

    for name <- Map.keys(networks), do: {name, "vcan0"}
  end
end
