defmodule OneDHCPD.Server do
  @moduledoc """
  This is the OneDHCPD Server.

  Add it to a supervision tree in your application to use. E.g.,

  ```elixir
  {OneDHCPD.Server, ["usb0", [subnet: {172, 31, 246, 64}]}
  ```
  """
  use GenServer

  alias OneDHCPD.ARP
  alias OneDHCPD.IPCalculator
  alias OneDHCPD.Message

  require Logger

  @dhcp_server_port 67
  @dhcp_client_port 68
  @ip_broadcast {255, 255, 255, 255}

  defstruct [
    :ifname,
    :socket,
    :subnet,
    :subnet_mask,
    :our_ip_address,
    :their_ip_address
  ]

  @type t :: %__MODULE__{
          ifname: String.t(),
          socket: any(),
          subnet: :inet.ip4_address(),
          subnet_mask: :inet.ip4_address(),
          our_ip_address: :inet.ip4_address(),
          their_ip_address: :inet.ip4_address()
        }

  defp server_name(ifname) do
    Module.concat(__MODULE__, String.to_atom(ifname))
  end

  @doc false
  @spec child_spec([String.t(), ...]) :: Supervisor.child_spec()
  def child_spec([ifname, opts]) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [ifname, opts]},
      type: :worker,
      restart: :permanent,
      shutdown: 500
    }
  end

  @doc """
  Start a DHCP Server that works for one client

  Options:

  * `port` - the port for the server (only specify if testing)
  * `subnet` - a /30 subnet to allocate addresses (default is {192, 168, 200, 0})
  """
  @spec start_link(String.t(), keyword()) :: GenServer.on_start()
  def start_link(ifname, options) do
    GenServer.start_link(__MODULE__, [{:ifname, ifname} | options], name: server_name(ifname))
  end

  @spec stop(String.t()) :: :ok
  def stop(ifname) do
    GenServer.stop(server_name(ifname))
  end

  @impl GenServer
  def init(options) do
    ifname = Keyword.get(options, :ifname)
    port = Keyword.get(options, :port, @dhcp_server_port)
    subnet = Keyword.get(options, :subnet) || IPCalculator.default_subnet(ifname)
    subnet_mask = IPCalculator.mask()
    our_ip_address = IPCalculator.our_ip_address(subnet)
    their_ip_address = IPCalculator.their_ip_address(subnet)

    socket_opts = [
      :binary,
      {:bind_to_device, ifname},
      {:broadcast, true},
      {:active, true}
    ]

    case :gen_udp.open(port, socket_opts) do
      {:ok, socket} ->
        {:ok,
         %__MODULE__{
           socket: socket,
           ifname: ifname,
           subnet: subnet,
           subnet_mask: subnet_mask,
           our_ip_address: our_ip_address,
           their_ip_address: their_ip_address
         }}

      {:error, :einval} ->
        Logger.error("OneDHCPD can't open port #{port} on #{ifname}. Check permissions")
        {:stop, :check_port_and_ifname}

      {:error, other} ->
        {:stop, other}
    end
  end

  @impl GenServer
  def handle_info(
        {:udp, socket, _ip, @dhcp_client_port, packet},
        state = %__MODULE__{socket: socket}
      ) do
    case Message.decode(packet) do
      {:error, _reason} ->
        # Bad packet?
        {:noreply, state}

      message ->
        message_type = Keyword.get(message.options, :dhcp_message_type)

        handle_dhcp(message_type, message, state)
    end
  end

  def handle_info(data, state) do
    Logger.error("dhcpd: not sure what to do with #{inspect(data)}")
    {:noreply, state}
  end

  defp handle_dhcp(:discover, message, state) do
    Logger.debug("Responding to DHCP discover on #{state.ifname}")

    # Handle a DHCP Discover message
    response =
      Message.response(message)
      |> Map.put(:yiaddr, state.their_ip_address)
      |> Map.put(:siaddr, state.our_ip_address)
      |> Map.put(:options,
        dhcp_message_type: :offer,
        subnet_mask: state.subnet_mask,
        dhcp_server_identifier: state.our_ip_address,
        dhcp_lease_time: 86400
      )

    dhcp_packet = Message.encode(response)

    :ok = :gen_udp.send(state.socket, @ip_broadcast, @dhcp_client_port, dhcp_packet)
    {:noreply, state}
  end

  defp handle_dhcp(:request, message, state) do
    Logger.debug("Responding to DHCP request on #{state.ifname}")

    if message.options[:dhcp_requested_address] == state.their_ip_address do
      # Send an DHCP ack
      response =
        Message.response(message)
        |> Map.put(:yiaddr, state.their_ip_address)
        |> Map.put(:siaddr, state.our_ip_address)
        |> Map.put(:options,
          dhcp_message_type: :ack,
          subnet_mask: state.subnet_mask,
          dhcp_server_identifier: state.our_ip_address,
          dhcp_lease_time: message.options[:dhcp_lease_time] || 86400
        )

      # Update our ARP cache so that we can send a response
      # directly to the client device.
      :ok = ARP.replace(state.ifname, state.their_ip_address, message.chaddr)

      dhcp_packet = Message.encode(response)

      :ok = :gen_udp.send(state.socket, state.their_ip_address, @dhcp_client_port, dhcp_packet)
    else
      # Send a DHCP nak
      response =
        Message.response(message)
        |> Map.put(:broadcast_flag, 1)
        |> Map.put(:siaddr, state.our_ip_address)
        |> Map.put(:options,
          dhcp_message_type: :nak,
          dhcp_server_identifier: state.our_ip_address,
          dhcp_message: "requested address not available"
        )

      dhcp_packet = Message.encode(response)

      :ok = :gen_udp.send(state.socket, @ip_broadcast, @dhcp_client_port, dhcp_packet)
    end

    {:noreply, state}
  end

  defp handle_dhcp(_message_type, message, state) do
    Logger.info("Ignoring DHCP message: #{inspect(message)}")
    {:noreply, state}
  end

  @impl GenServer
  def terminate(_, state) do
    :gen_udp.close(state.socket)
  end
end
