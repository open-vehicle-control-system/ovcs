defmodule OvcsInfotainmentBackend.Can.Util do
  alias OvcsInfotainmentBackend.Can.Frame

  @can_domain 29
  @can_protocol 1
  @can_type :raw

  def setup_can_interface(interface, bitrate) do
    IO.inspect :os.cmd('ip link set #{interface} type can bitrate #{bitrate}')
    IO.inspect :os.cmd('ip link set #{interface} up type can')
    :ok
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
