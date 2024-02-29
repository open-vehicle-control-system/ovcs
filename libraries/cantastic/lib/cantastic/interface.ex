defmodule Cantastic.Interface do
  alias Cantastic.{FrameSpecification, Receiver, Emitter, ConfigurationStore}
  require Logger

  @can_domain 29
  @can_protocol 1
  @can_type :raw

  def configure_children() do
    interface_specs = ConfigurationStore.networks() |> Enum.map(fn (network) ->
      {:ok, socket} = initialize_socket(network.interface, network.bitrate, ConfigurationStore.setup_can_interfaces())
      %{
        network_name: network.network_name,
        network_config: network.network_config,
        socket: socket
      }
    end)

    receivers = configure_receivers(interface_specs)
    emitters  = configure_emitters(interface_specs)
    receivers ++ emitters
  end

  def configure_receivers(interface_specs) do
    interface_specs
    |> Enum.map(fn (%{network_name: network_name, network_config: network_config, socket: socket}) ->
      process_name                  = receiver_process_name(network_name)
      received_frame_specifications = compute_frame_specifications((network_config[:received_frames] || []), network_name)
      Supervisor.child_spec({Receiver, [process_name, network_name, socket, received_frame_specifications]}, id: process_name)
    end)
  end

  def configure_emitters(interface_specs) do
    interface_specs
    |> Enum.map(fn (%{network_name: network_name, network_config: network_config, socket: socket}) ->
      (network_config[:emitted_frames] || [])
      |> compute_frame_specifications(network_name)
      |> Enum.map(fn({_frame_id, frame_specification}) ->
        arguments = %{
          socket: socket,
          network_name: network_name,
          process_name: emitter_process_name(network_name, frame_specification.name),
          frame_specification: frame_specification
        }
        Supervisor.child_spec({Emitter, arguments}, id: arguments.process_name)
      end)
    end)
    |> List.flatten
  end

  def receiver_process_name(network_name) do
    network_name = network_name |> Atom.to_string()
    "Cantastic#{network_name |> String.capitalize()}Receiver" |> String.to_atom
  end

  def emitter_process_name(network_name, frame_name) do
    network_name = network_name |> Atom.to_string()
    "Cantastic#{network_name |> String.capitalize()}#{frame_name |> String.capitalize()}Emitter" |> String.to_atom
  end

  defp initialize_socket(interface, bitrate, setup_can_interfaces) do
    case setup_can_interface(interface, bitrate, setup_can_interfaces) do
      :ok -> bind_socket(interface)
    end
  end

  # {800: name: "handbrakeStatus", signals: [{name: 'handbrakeEngaged', value: true, mapping: ....}, {name: 'handbrakeError': {value: true, ...}}]}
  defp compute_frame_specifications(yaml_frame_specifications, network_name) do
    yaml_frame_specifications
    |> Enum.reduce(%{}, fn(yaml_frame_specification, frame_specifications) ->
      {:ok, frame_specification} = FrameSpecification.from_frame_specification(network_name, yaml_frame_specification)
      frame_specifications |> Map.put(frame_specification.id, frame_specification)
    end)
  end

  defp setup_can_interface(interface, bitrate, setup_can_interfaces \\ false, retry_number \\ 0)
  defp setup_can_interface(interface, _bitrate, _setup_can_interfaces, 40) do
    Logger.error("Could not open CAN bus interface #{interface}")
  end
  defp setup_can_interface(interface, bitrate, setup_can_interfaces, retry_number) when binary_part(interface, 0, 4) == "vcan" do
    with  {output, 0} <- System.cmd("ip", ["link", "show", interface]),
          false       <- output |> String.match?(~r/state DOWN/)
    do
      Logger.info("Connection to #{interface} initialized")
      :ok
    else
      _ -> Logger.warning("""
          Please enable virtual CAN bus interface: #{interface} manually with the following commands:
          $ sudo ip link add dev #{interface} type vcan
          $ sudo ip link set up #{interface}
          The applicaltion will start working once done
        """)
        :timer.sleep(1000)
        setup_can_interface(interface, bitrate, setup_can_interfaces, retry_number + 1)
    end
  end
  defp setup_can_interface(interface, _bitrate, false = _setup_can_interfaces, _retry_number) do
    Logger.info("Connection to the CAN bus #{interface} skipped following can interface setup config")
    :ok
  end
  defp setup_can_interface(interface, bitrate, true = setup_can_interfaces, retry_number) do
    with  {_output, 0} <- System.cmd("ip", ["link", "set", interface, "type", "can", "bitrate", "#{bitrate}"], stderr_to_stdout: true),
          {_output, 0} <- System.cmd("ip", ["link", "set", interface, "txqueuelen", "1000"], stderr_to_stdout: true),
          {_output, 0} <- System.cmd("ip", ["link", "set", interface, "up"], stderr_to_stdout: true)
    do
      Logger.info("Connection to the CAN bus #{interface} with a  bitrate of #{bitrate} bit/seconds initialized")
      :ok
    else
      {"RTNETLINK answers: Operation not permitted\n", _} ->
        Logger.error("""
          The connection to the CAN bus interface #{interface} cannot be open.
          This system probably requires to setup the interface manually with sudo.
          You should then set the SETUP_CAN_INTERFACES env variable to "false"
        """)
        System.stop(1)
      {output, _} ->
        Logger.warning("The connection to the CAN bus interface #{interface} failed with the following reason: '#{output}'Retrying in 0.5 seconds.")
        :timer.sleep(500)
        setup_can_interface(interface, bitrate, setup_can_interfaces, retry_number + 1)
    end
  end

  defp bind_socket(interface) do
    charlist_interface = interface |> String.to_charlist()
    with {:ok, socket}  <- :socket.open(@can_domain, @can_type, @can_protocol),
         {:ok, ifindex} <- :socket.ioctl(socket, :gifindex, charlist_interface),
         {:ok, address} <- socket_address(ifindex),
         :ok            <- :socket.bind(socket, %{:family => @can_domain, :addr => address})
    do
      {:ok, socket}
    else
      {:error, :enodev} -> {:error, "CAN interface not found by libsocketcan. Make sure it is configured and enabled first with '$ ip link show'"}
      {:error, error} -> {:error, error}
    end
  end

  defp socket_address(ifindex) do
    address = <<0::size(16)-little, ifindex::size(32)-little, 0::size(32), 0::size(32), 0::size(64)>>
    {:ok, address}
  end
end
