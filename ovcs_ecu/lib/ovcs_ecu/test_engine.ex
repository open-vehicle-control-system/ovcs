defmodule OvcsEcu.TestEngine do
  use GenServer
  alias Cantastic.{Frame}
  use Bitwise

  @stop_torque 0

  def start_link(args) do
    GenServer.start_link(__MODULE__, args)
  end

  @impl true
  def init(_args) do
    vms_status_task = Task.async(fn ->
      send_vms_status_message(0)
    end)

    keepalive_task = Task.async(fn ->
      send_keep_alive_message()
    end)

    torque_loop()
    {:ok,
      %{
        vms: vms_status_task,
        keepalive: keepalive_task,
        torque: @stop_torque,
        torque_counter: 0
      }
    }
  end

  @impl true
  def handle_info(:torque_loop, state) do
    send_torque_message(state.torque, state.torque_counter)
    torque_loop()
    {:noreply, %{state | torque_counter: rem(state.torque_counter+1, 4)}}
  end

  @impl true
  def handle_cast(:stop_engine, state) do
    {:noreply, %{state | torque: @stop_torque}}
  end

  @impl true
  def handle_cast({:throttle_engine, torque}, state) do
    {:noreply, %{state | torque: torque}}
  end

  def start() do
    {:ok, _} = GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  def throttle_engine(torque) do
    GenServer.cast(__MODULE__, {:throttle_engine, torque})
  end

  def stop_engine() do
    GenServer.cast(__MODULE__, :stop_engine)
  end

  defp torque_loop do
    Process.send_after(__MODULE__, :torque_loop, 10)
  end

  def send_torque_message(torque, counter) do
    prefix = "6E6E"
    raw_torque = <<torque::big-integer-size(16)>>
    hex_torque = raw_torque |> Base.encode16()
    hex_counter = compute_hex_shifted_counter(counter)
    postfix = "4401"
    crc = compute_crc(prefix <> hex_torque <> hex_counter <> postfix)
    Frame.send("drive", "1D4", prefix <> hex_torque <> hex_counter <> postfix <> crc)
  end

  def send_keep_alive_message() do
    Frame.send("drive", "50B", "000006C0000000")
    :timer.sleep(100)
    send_keep_alive_message()
  end

  def send_vms_status_message(counter) do
    prefix      = "4E4000AAC000"
    hex_counter = compute_hex_counter(counter)
    crc         = compute_crc(prefix <> hex_counter)
    Frame.send("drive", "11A", prefix <> hex_counter <> crc)
    :timer.sleep(10)
    send_vms_status_message(rem(counter+1, 4))
  end

  def compute_crc(hex_data) do
    {:ok, raw_data} = Base.decode16(hex_data)
    CRC.calculate(
      raw_data,
      %{
        width: 8,
        poly: 0x85,
        init: 0x00,
        refin: false,
        refout: false,
        xorout: 0x00
      }
    ) |> Integer.to_string(16) |> String.pad_leading(2, "0")
  end

  def compute_hex_counter(counter) do
    counter |> Integer.to_string(16) |> String.pad_leading(2, "0")
  end

  def compute_hex_shifted_counter(counter) do
    bxor(7, counter <<< 6) |> Integer.to_string(16) |> String.pad_leading(2, "0")
  end
end
