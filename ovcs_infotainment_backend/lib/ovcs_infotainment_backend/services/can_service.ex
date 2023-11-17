defmodule OvcsInfotainmentBackend.CanService do
  @can_domain 29
  @can_protocol 1
  @can_type :raw

  def setup_can_interface(interface, bitrate) do
    :os.cmd('ip link set #{interface} type can bitrate #{bitrate}')
    :os.cmd('ip link set #{interface} up type can')
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
    {:ok, frame} = :socket.recv(socket)
    <<frame_id::binary-size(2), _unused1::binary-size(2), frame_data_length::binary-size(1), _unused2::binary-size(3), frame_data::binary  >> = frame
    encoded_frame_id = Base.encode16(frame_id)
    encoded_frame_data_length = :binary.decode_unsigned(frame_data_length)
    encoded_frame_data = Base.encode16(frame_data)
    {:ok, %{id: encoded_frame_id, length: encoded_frame_data_length, data: encoded_frame_data, raw_frame: frame}}
  end

  def send_frame(socket, raw_frame) do
    :socket.send(socket, raw_frame)
  end
end
