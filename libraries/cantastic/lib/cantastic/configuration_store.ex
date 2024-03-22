defmodule Cantastic.ConfigurationStore do
  use Agent

  def start_link(_) do
    networks = compute_networks()
    state = %{
      networks: networks,
      setup_can_interfaces: Application.get_env(:cantastic, :setup_can_interfaces) || false,
      socketcand_ip_interface: Application.get_env(:cantastic, :socketcand_ip_interface) || "eth0",
      enable_socketcand: Application.get_env(:cantastic, :enable_socketcand) || false,
    }
    Agent.start_link(fn -> state end, name: __MODULE__)
  end

  def network_names() do
    Agent.get(__MODULE__, fn(state) ->
      state.networks |> Enum.map(fn(network) ->
        network.name
      end)
    end)
  end

  def networks() do
    Agent.get(__MODULE__, fn(state) ->
      state.networks
    end)
  end

  def socketcand_ip_interface() do
    Agent.get(__MODULE__, fn(state) ->
      state.socketcand_ip_interface
    end)
  end

  def enable_socketcand() do
    Agent.get(__MODULE__, fn(state) ->
      state.enable_socketcand
    end)
  end

  def setup_can_interfaces() do
    Agent.get(__MODULE__, fn(state) ->
      state.setup_can_interfaces
    end)
  end

  defp compute_can_configuration() do
    opt_app              = Application.get_env(:cantastic, :otp_app)
    priv_can_config_path = Application.get_env(:cantastic, :priv_can_config_path)
    config_path          = Path.join(:code.priv_dir(opt_app), priv_can_config_path)
    with {:ok, config}  <- YamlElixir.read_from_file(config_path, atoms: true),
         {:ok, encoded} <- Jason.encode(config)
    do
      encoded |> Jason.decode(keys: :atoms)
    else
      {:error, error} -> {:error, error}
    end
  end

  defp compute_networks() do
    raw_can_network_specifications = Application.get_env(:cantastic, :can_networks) |> String.split(",", trim: true)
    {:ok, config}                  = compute_can_configuration()
    Enum.map(raw_can_network_specifications, fn (raw_can_network_specification) ->
      [network_name, interface] = raw_can_network_specification |> String.split(":")
      network_name              = network_name |> String.to_atom()
      network_config            = config.can_networks[network_name]
      bitrate                   = network_config.bitrate
      %{
        network_name: network_name,
        interface: interface,
        network_config: network_config,
        bitrate: bitrate
      }
    end)
  end
end
