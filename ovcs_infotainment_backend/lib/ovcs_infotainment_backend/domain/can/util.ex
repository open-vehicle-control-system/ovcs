defmodule OvcsInfotainmentBackend.Can.Util do
  alias OvcsInfotainmentBackend.Can.Frame
  require Logger

  @can_domain 29
  @can_protocol 1
  @can_type :raw

  def setup_can_interface(interface, bitrate, manual_setup \\ false, retry_number \\ 0)
  def setup_can_interface(interface, _bitrate, _manual_setup, 40) do
    Logger.error("Could not open CAN bus interface #{interface} shutting down")
    System.stop(1)
  end
  def setup_can_interface(interface, bitrate, _manual_setup, retry_number) when binary_part(interface, 0, 4) == "vcan" do
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
        setup_can_interface(interface, bitrate, retry_number + 1)
    end
  end
  def setup_can_interface(interface, _bitrate, true, _retry_number) do
    Logger.info("Connection to the CAN bus #{interface} skipped due to manual setup config")
    :ok
  end
  def setup_can_interface(interface, bitrate, manual_setup, retry_number) do
    with  {_output, 0} <- System.cmd("ip", ["link", "set", interface, "type", "can", "bitrate", bitrate], stderr_to_stdout: true),
          {_output, 0} <- System.cmd("ip", ["link", "set", interface, "up"], stderr_to_stdout: true)
    do
      Logger.info("Connection to the CAN bus #{interface} with a  bitrate of #{bitrate} bit/seconds initialized")
      :ok
    else
      {output, _} ->
        Logger.warning("The connection to the CAN bus interface #{interface} failed with the following reason: '#{output}'Retrying in 0.5 seconds.")
        :timer.sleep(500)
        setup_can_interface(interface, bitrate, retry_number + 1)
    end
  end

  def bind_socket(interface) do
    {:ok, socket} = :socket.open(@can_domain, @can_type, @can_protocol)
    charlist_interface = interface |> String.to_charlist()
    {:ok, ifindex} = :socket.ioctl(socket, :gifindex, charlist_interface)
    address = <<0::size(16)-little, ifindex::size(32)-little, 0::size(32), 0::size(32), 0::size(64)>>
    :socket.bind(socket, %{:family => @can_domain, :addr => address})
    {:ok, socket}
  end

  def receive_one_frame(socket) do
    {:ok, raw_frame} = :socket.recv(socket)
    <<
      id::little-integer-size(16),
      _unused1::binary-size(2),
      data_length::little-integer-size(8),
      _unused2::binary-size(3),
      raw_data::binary-size(data_length),
      _unused3::binary
    >> = raw_frame
    frame = %Frame{
      id: id,
      data_length: data_length * 8,
      raw_data: raw_data
    }
    {:ok, frame}
  end

  def send_frame(socket, raw_frame) do
    :socket.send(socket, raw_frame)
  end
end
