defmodule Cantastic.Util do
  require Logger

  @can_domain 29
  @can_protocol 1
  @can_type :raw

  def setup_can_interface(interface, bitrate, setup_can_interfaces \\ false, retry_number \\ 0)
  def setup_can_interface(interface, _bitrate, _setup_can_interfaces, 40) do
    Logger.error("Could not open CAN bus interface #{interface} shutting down")
    System.stop(1)
  end
  def setup_can_interface(interface, bitrate, setup_can_interfaces, retry_number) when binary_part(interface, 0, 4) == "vcan" do
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
  def setup_can_interface(interface, _bitrate, false = _setup_can_interfaces, _retry_number) do
    Logger.info("Connection to the CAN bus #{interface} skipped following can interface setup config")
    :ok
  end
  def setup_can_interface(interface, bitrate, true = setup_can_interfaces, retry_number) do
    with  {_output, 0} <- System.cmd("ip", ["link", "set", interface, "type", "can", "bitrate", "#{bitrate}"], stderr_to_stdout: true),
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

  def bind_socket(interface) do
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

  def hex_to_bin(nil), do: nil
  def hex_to_bin(hex_data) do
    hex_data
    |> String.pad_leading(2, "0")
    |> Base.decode16!()
  end

  def bin_to_hex(raw_data) do
    raw_data |> Base.encode16()
  end

  def integer_to_hex(integer) do
    integer
    |> Integer.to_string(16)
    |> String.pad_leading(2, "0")
  end

  def string_to_integer(string) do
    {int, _} = Integer.parse(string)
    int
  end

  def integer_to_bin_big(integer, size \\ 16) do
    <<integer::big-integer-size(size)>>
  end

  def integer_to_bin_little(integer, size \\ 16) do
    <<integer::little-integer-size(size)>>
  end

  def unsigned_integer_to_bin_big(nil), do: nil
  def unsigned_integer_to_bin_big(integer) do
    :binary.encode_unsigned(integer)
  end
end
