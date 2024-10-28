defmodule VintageNetWiFi.WPASupplicantLL do
  @moduledoc """
  This modules provides a low-level interface for interacting with the `wpa_supplicant`

  Example use:

  ```elixir
  iex> {:ok, ws} = VintageNetWiFi.WPASupplicantLL.start_link(path: "/tmp/vintage_net/wpa_supplicant/wlan0", notification_pid: self())
  {:ok, #PID<0.1795.0>}
  iex> VintageNetWiFi.WPASupplicantLL.control_request(ws, "ATTACH")
  {:ok, "OK\n"}
  iex> VintageNetWiFi.WPASupplicantLL.control_request(ws, "SCAN")
  {:ok, "OK\n"}
  iex> flush
  {VintageNetWiFi.WPASupplicant, 51, "CTRL-EVENT-SCAN-STARTED "}
  {VintageNetWiFi.WPASupplicant, 51, "CTRL-EVENT-BSS-ADDED 0 78:8a:20:87:7a:50"}
  {VintageNetWiFi.WPASupplicant, 51, "CTRL-EVENT-SCAN-RESULTS "}
  {VintageNetWiFi.WPASupplicant, 51, "CTRL-EVENT-NETWORK-NOT-FOUND "}
  :ok
  iex> VintageNetWiFi.WPASupplicantLL.control_request(ws, "BSS 0")
  {:ok,
  "id=0\nbssid=78:8a:20:82:7a:50\nfreq=2437\nbeacon_int=100\ncapabilities=0x0431\nqual=0\nnoise=-89\nlevel=-71\ntsf=0000333220048880\nage=14\nie=0008426f7062654c414e010882848b968c1298240301062a01003204b048606c0b0504000a00002d1aac011bffffff00000000000000000001000000000000000000003d1606080c000000000000000000000000000000000000007f080000000000000040dd180050f2020101000003a4000027a4000042435e0062322f00dd0900037f01010000ff7fdd1300156d00010100010237e58106788a20867a5030140100000fac040100000fac040100000fac020000\nflags=[WPA2-PSK-CCMP][ESS]\nssid=HelloWiFi\nsnr=18\nest_throughput=48000\nupdate_idx=1\nbeacon_ie=0008426f7062654c414e010882848b968c1298240301060504010300002a01003204b048606c0b0504000a00002d1aac011bffffff00000000000000000001000000000000000000003d1606080c000000000000000000000000000000000000007f080000000000000040dd180050f2020101000003a4000027a4000042435e0062322f00dd0900037f01010000ff7fdd1300156d00010100010237e58106788a20867a5030140100000fac040100000fac040100000fac020000\n"}
  ```
  """
  use GenServer
  require Logger

  defstruct control_file: nil,
            socket: nil,
            request_queue: :queue.new(),
            outstanding: nil,
            notification_pid: nil,
            request_timer: nil

  @doc """
  Start the WPASupplicant low-level interface

  Pass the path to the wpa_supplicant control file.

  Notifications from the wpa_supplicant are sent to the process that
  calls this.
  """
  @spec start_link(path: Path.t(), notification_pid: pid()) :: GenServer.on_start()
  def start_link(init_args) do
    GenServer.start_link(__MODULE__, init_args)
  end

  @spec control_request(GenServer.server(), binary()) :: {:ok, binary()} | {:error, any()}
  def control_request(server, request) do
    GenServer.call(server, {:control_request, request})
  end

  @impl GenServer
  def init(init_args) do
    path = Keyword.fetch!(init_args, :path)
    pid = Keyword.fetch!(init_args, :notification_pid)

    # Blindly create the control interface's directory in case we beat
    # wpa_supplicant.
    _ = File.mkdir_p(Path.dirname(path))

    # The path to our end of the socket so that wpa_supplicant can send us
    # notifications and responses
    our_path = path <> ".ex"

    # Blindly remove an old file just in case it exists from a previous run
    _ = File.rm(our_path)

    {:ok, socket} =
      :gen_udp.open(0, [:local, :binary, {:active, true}, {:ip, {:local, our_path}}])

    state = %__MODULE__{
      control_file: path,
      socket: socket,
      notification_pid: pid
    }

    {:ok, state}
  end

  @impl GenServer
  def handle_call({:control_request, message}, from, state) do
    new_state =
      state
      |> enqueue_request(message, from)
      |> maybe_send_request()

    {:noreply, new_state}
  end

  @impl GenServer
  def handle_info(
        {:udp, socket, _, 0, <<?<, priority, ?>, notification::binary>>},
        %{socket: socket, notification_pid: pid} = state
      ) do
    send(pid, {__MODULE__, priority - ?0, notification})
    {:noreply, state}
  end

  def handle_info({:udp, socket, _, 0, response}, %{socket: socket, outstanding: request} = state)
      when not is_nil(request) do
    {_message, from} = request
    _ = :timer.cancel(state.request_timer)

    GenServer.reply(from, {:ok, response})

    new_state = %{state | outstanding: nil} |> maybe_send_request()
    {:noreply, new_state}
  end

  def handle_info(:request_timeout, %{outstanding: request} = state)
      when not is_nil(request) do
    {_message, from} = request

    GenServer.reply(from, {:error, :timeout})
    new_state = %{state | outstanding: nil} |> maybe_send_request()

    {:noreply, new_state}
  end

  def handle_info(message, state) do
    Logger.error("wpa_supplicant_ll: unexpected message: #{inspect(message)}")
    {:noreply, state}
  end

  defp enqueue_request(state, message, from) do
    new_request_queue = :queue.in({message, from}, state.request_queue)

    %{state | request_queue: new_request_queue}
  end

  defp maybe_send_request(%{outstanding: nil} = state) do
    case :queue.out(state.request_queue) do
      {:empty, _} ->
        state

      {{:value, request}, new_queue} ->
        %{state | request_queue: new_queue}
        |> do_send_request(request)
    end
  end

  defp maybe_send_request(state), do: state

  defp do_send_request(state, {message, from} = request) do
    case :gen_udp.send(state.socket, {:local, state.control_file}, 0, message) do
      :ok ->
        {:ok, timer} = :timer.send_after(4000, :request_timeout)
        %{state | outstanding: request, request_timer: timer}

      error ->
        Logger.error("wpa_supplicant_ll: Error sending #{inspect(message)} (#{inspect(error)})")
        GenServer.reply(from, error)
        maybe_send_request(state)
    end
  end
end
