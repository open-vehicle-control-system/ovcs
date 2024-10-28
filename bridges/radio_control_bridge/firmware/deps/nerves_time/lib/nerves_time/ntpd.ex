defmodule NervesTime.Ntpd do
  @moduledoc false
  use GenServer
  require Logger

  # If restarting ntpd due to a crash, delay its start to avoid pegging
  # ntp servers. This delay can be long since the clock has either been
  # set (i.e., it's not far off from the actual time) or there is a problem
  # setting the time that has a low probability of being fixed by trying
  # again immediately. Plus ntp server admins get annoyed by misbehaving
  # IoT devices pegging their servers and we don't want that.
  @ntpd_restart_delay 60_000
  @ntpd_clean_start_delay 10

  @default_ntpd_path "/usr/sbin/ntpd"
  @default_ntp_servers [
    "0.pool.ntp.org",
    "1.pool.ntp.org",
    "2.pool.ntp.org",
    "3.pool.ntp.org"
  ]

  defmodule State do
    @moduledoc false
    @type t() :: %__MODULE__{
            socket: :gen_udp.socket(),
            servers: [String.t()],
            daemon: nil | pid(),
            synchronized?: boolean(),
            clean_start?: boolean()
          }
    defstruct socket: nil,
              servers: [],
              daemon: nil,
              synchronized?: false,
              clean_start?: true
  end

  @spec start_link(any()) :: GenServer.on_start()
  def start_link(_args) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @doc """
  Return whether ntpd has synchronized with a time server
  """
  @spec synchronized?() :: boolean()
  def synchronized?() do
    GenServer.call(__MODULE__, :synchronized?)
  end

  @doc """
  Return whether ntpd was started cleanly

  If ntpd crashes or this GenServer crashes, then the run is considered
  unclean and there's a delay in starting ntpd. This is intended to
  prevent abusive polling of public ntpd servers.
  """
  @spec clean_start?() :: boolean()
  def clean_start?() do
    GenServer.call(__MODULE__, :clean_start?)
  end

  @doc """
  Update the list of NTP servers to poll
  """
  @spec set_ntp_servers([String.t()]) :: :ok
  def set_ntp_servers(servers) when is_list(servers) do
    GenServer.call(__MODULE__, {:set_ntp_servers, servers})
  end

  @doc """
  Get the list of NTP servers
  """
  @spec ntp_servers() :: [String.t()] | {:error, term()}
  def ntp_servers() do
    GenServer.call(__MODULE__, :ntp_servers)
  end

  @doc """
  Manually restart ntpd
  """
  @spec restart_ntpd() :: :ok | {:error, term()}
  def restart_ntpd() do
    GenServer.call(__MODULE__, :restart_ntpd)
  end

  @impl GenServer
  def init(_args) do
    app_env = Application.get_all_env(:nerves_time)
    ntp_servers = Keyword.get(app_env, :servers, @default_ntp_servers)

    {:ok, %State{servers: ntp_servers}, {:continue, :continue}}
  end

  @impl GenServer
  def handle_continue(:continue, state) do
    new_state =
      state
      |> prep_ntpd_start()
      |> schedule_ntpd_start()

    {:noreply, new_state}
  end

  @impl GenServer
  def handle_call(:synchronized?, _from, state) do
    {:reply, state.synchronized?, state}
  end

  @impl GenServer
  def handle_call(:clean_start?, _from, state) do
    {:reply, state.clean_start?, state}
  end

  @impl GenServer
  def handle_call({:set_ntp_servers, servers}, _from, state) do
    new_state = %{state | servers: servers} |> cleanup_and_restart()

    {:reply, :ok, new_state}
  end

  @impl GenServer
  def handle_call(:ntp_servers, _from, %State{servers: servers} = state) do
    {:reply, servers, state}
  end

  @impl GenServer
  def handle_call(:restart_ntpd, _from, state) do
    {:reply, :ok, cleanup_and_restart(state)}
  end

  @impl GenServer
  def handle_info(:start_ntpd, %State{daemon: nil, servers: servers} = state)
      when servers != [] do
    new_state = start_ntpd(state)
    {:noreply, new_state}
  end

  @impl GenServer
  def handle_info(:start_ntpd, state) do
    # Ignore since ntpd is already running or there are no servers
    {:noreply, state}
  end

  @impl GenServer
  def handle_info({:udp, socket, _, 0, data}, %{socket: socket} = state) do
    report = :erlang.binary_to_term(data)
    handle_ntpd_report(report, state)
  end

  def handle_info({:EXIT, _pid, :normal}, state) do
    # Normal exits come from the ntpd daemon and calls to set the time.
    # They're initiated by us, so they can be safely ignored.
    {:noreply, state}
  end

  def handle_info({:EXIT, from, reason}, state) do
    # Log abnormal exits to aide debugging.
    Logger.info("[NervesTime] unexpected ntpd :EXIT #{inspect(from)}/#{inspect(reason)}")
    {:stop, reason, state}
  end

  defp prep_ntpd_start(%State{servers: []} = state) do
    # Don't prep ntpd if no servers are configured.
    state
  end

  defp prep_ntpd_start(state) do
    path = socket_path()

    # Cleanup the socket file in case of a restart
    clean_start =
      case File.rm(path) do
        {:error, :enoent} ->
          # This is the expected case. There's no stale socket file sitting around
          true

        :ok ->
          Logger.warning("[NervesTime] ntpd crash detected. Delaying next start...")
          false
      end

    {:ok, socket} = :gen_udp.open(0, [:local, :binary, {:active, true}, {:ip, {:local, path}}])

    %State{state | socket: socket, clean_start?: clean_start}
  end

  defp schedule_ntpd_start(%State{servers: []} = state) do
    # Don't schedule ntpd to start if no servers configured.
    Logger.info("[NervesTime] Not scheduling ntpd to start (no servers configured)")
    state
  end

  defp schedule_ntpd_start(state) do
    delay = ntpd_restart_delay(state)
    Process.send_after(self(), :start_ntpd, delay)
    state
  end

  defp cleanup_and_restart(state) do
    state
    |> stop_ntpd()
    |> prep_ntpd_start()
    |> schedule_ntpd_start()
  end

  defp ntpd_restart_delay(%State{clean_start?: false}), do: @ntpd_restart_delay
  defp ntpd_restart_delay(%State{clean_start?: true}), do: @ntpd_clean_start_delay

  defp stop_ntpd(%State{daemon: pid, socket: socket} = state) do
    unless is_nil(pid) do
      GenServer.stop(pid)
    end

    unless is_nil(socket) do
      :ok = :gen_udp.close(socket)
    end

    # this is needed otherwise dialyzer complains
    try do
      File.rm!(socket_path())
    rescue
      _ -> nil
    end

    %State{state | daemon: nil, socket: nil, synchronized?: false}
  end

  defp handle_ntpd_report({"stratum", _freq_drift_ppm, _offset, stratum, _poll_interval}, state) do
    {:noreply, %State{state | synchronized?: maybe_update_rtc(stratum)}}
  end

  defp handle_ntpd_report({"periodic", _freq_drift_ppm, _offset, stratum, _poll_interval}, state) do
    {:noreply, %State{state | synchronized?: maybe_update_rtc(stratum)}}
  end

  defp handle_ntpd_report({"step", _freq_drift_ppm, _offset, _stratum, _poll_interval}, state) do
    # Ignore
    {:noreply, state}
  end

  defp handle_ntpd_report({"unsync", _freq_drift_ppm, _offset, _stratum, _poll_interval}, state) do
    Logger.error("[NervesTime] ntpd reports that it is unsynchronized; restarting")

    # According to the Busybox ntpd docs, if you get an `unsync` notification, then
    # you should restart ntpd to be safe. This is stated to be due to name resolution
    # only being done at initialization.
    new_state =
      state
      |> stop_ntpd()
      |> schedule_ntpd_start()

    {:noreply, new_state}
  end

  defp handle_ntpd_report(report, state) do
    Logger.error("[NervesTime] ntpd ignored unexpected report #{inspect(report)}")
    {:noreply, state}
  end

  defp start_ntpd(%State{servers: []} = state), do: state

  defp start_ntpd(%State{servers: servers} = state) do
    ntpd_path = Application.get_env(:nerves_time, :ntpd, @default_ntpd_path)
    ntpd_script_path = Application.app_dir(:nerves_time, ["priv", "ntpd_script"])

    server_args = Enum.flat_map(servers, fn s -> ["-p", s] end)

    # Add "-d" and enable log_output below for more verbose prints from ntpd.
    args = ["-n", "-S", ntpd_script_path | server_args]

    Logger.debug("[NervesTime] starting #{ntpd_path} with: #{inspect(args)}")

    {:ok, pid} =
      MuonTrap.Daemon.start_link(ntpd_path, args,
        env: [{"SOCKET_PATH", socket_path()}],
        stderr_to_stdout: true
        # log_output: :debug
      )

    %{state | daemon: pid, synchronized?: false}
  end

  # Only update the RTC if synchronized. I.e., ignore stratum > 4
  @spec maybe_update_rtc(integer()) :: boolean()
  defp maybe_update_rtc(stratum)
       when stratum <= 4 do
    NervesTime.SystemTime.update_rtc()
    true
  end

  defp maybe_update_rtc(_stratum), do: false

  defp socket_path() do
    Path.join(System.tmp_dir!(), "nerves_time_comm")
  end
end
