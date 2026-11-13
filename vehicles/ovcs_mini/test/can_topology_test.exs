defmodule OvcsMini.CanTopologyTest do
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

  for composer <- [OvcsMini.Vms.Composer] do
    test "#{inspect(composer)} topology loads" do
      assert [_ | _] = load_topology(:ovcs_mini, unquote(composer).can_config_path())
    end
  end

  test "the simulator's topology loads" do
    assert [_ | _] = load_topology(:ovcs_mini, OvcsMini.simulator().can_config_path)
  end

  test "the simulator's topology declares every frame its simulated components read and emit" do
    load_topology(:ovcs_mini, OvcsMini.simulator().can_config_path)

    declared =
      for network <- ConfigurationStore.networks(),
          direction <- [:received_frames, :emitted_frames],
          frame <- network.network_config[direction] || [],
          into: MapSet.new(),
          do: {network.network_name, direction, frame.name}

    for {module, opts} <- OvcsMini.simulator().simulated_components do
      {_state, received, emitted} = module.init(opts)

      for {network, name} <- received,
          do:
            assert(
              {network, :received_frames, name} in declared,
              "#{inspect(module)} reads #{network}.#{name}"
            )

      for {network, name, _signals} <- emitted,
          do:
            assert(
              {network, :emitted_frames, name} in declared,
              "#{inspect(module)} emits #{network}.#{name}"
            )
    end
  end

  test "the simulator maps its networks on the interfaces the VMS uses for them" do
    vms_interfaces = mapping(OvcsMini.Vms.Composer.default_can_mapping(:host))
    simulator_interfaces = mapping(OvcsMini.simulator().can_mapping)

    assert simulator_interfaces == Map.take(vms_interfaces, Map.keys(simulator_interfaces))

    assert Map.keys(simulator_interfaces) ==
             :ovcs_mini
             |> network_mappings(OvcsMini.simulator().can_config_path)
             |> Enum.map(&elem(&1, 0))
             |> Enum.sort()
  end

  defp mapping(host_mapping) do
    for pair <- String.split(host_mapping, ","), into: %{} do
      [network, interface] = String.split(pair, ":")
      {network, interface}
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
