defmodule VisionCore.Stereo.Matcher do
  @moduledoc """
  The `stereo_match` Port, which computes the stereo stages natively on
  every core of a CPU, for the `VisionCore.Stereo.NativeSegment`s of
  every pipeline. The Port holds each segment's state: what its stages
  carry from one pair to the next and what depends on their settings
  alone. Requests are computed one at a time, in the order they arrive,
  but need not wait for the previous reply: the Port reads a request
  while it computes the one before, and writes a reply while it computes
  the next. `send_run/5` sends one without waiting.

  A segment is configured on its first pair, and again once its version
  changes (a calibration reload) or the Port has restarted, which loses
  every segment's state. A segment is released when the process that
  ran it exits.

  The binary is `priv/stereo_match`, or `config :vision_core,
  :stereo_match_path`; it works on `config :vision_core,
  :stereo_match_threads` threads, or one per core. The Port opens on the
  first request and reopens after it exits. A request without a reply
  within `:timeout_ms` (`5000`) of being sent closes the Port, failing
  every request still waiting, so a late reply cannot answer another
  one. The Port's log lines go to the `Logger`.
  """
  use GenServer
  require Logger

  @default_timeout_ms 5_000
  @log_tag 2
  @configured_tag 7
  @outputs_tag 8
  @release 3

  @doc "Starts the matcher server; see the module doc for `opts`."
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  Runs `request` on segment `segment_id`, first configuring it with
  `configuration` unless the Port has it at `version`. The segment is
  released once `owner` exits. Returns the reply's payload, or
  `{:error, :bad_request}` when the Port refuses either request, having
  logged why. The protocol is the Port's; see
  `VisionCore.Stereo.NativeSegment`.
  """
  @spec run(pid(), non_neg_integer(), non_neg_integer(), iodata(), iodata()) ::
          {:ok, binary()} | {:error, term()}
  def run(owner, segment_id, version, configuration, request) do
    GenServer.call(
      __MODULE__,
      {:run, owner, segment_id, version, configuration, request},
      :infinity
    )
  end

  @doc """
  `run/5` without waiting for the reply: the caller receives it as a
  message that `:gen_server.check_response/2` recognises from the
  returned request id. Requests a process sends are computed in the
  order it sends them.
  """
  @spec send_run(pid(), non_neg_integer(), non_neg_integer(), iodata(), iodata()) ::
          :gen_server.request_id()
  def send_run(owner, segment_id, version, configuration, request),
    do:
      :gen_server.send_request(
        __MODULE__,
        {:run, owner, segment_id, version, configuration, request}
      )

  @impl GenServer
  def init(opts) do
    {:ok,
     %{
       port: nil,
       timeout_ms: Keyword.get(opts, :timeout_ms, @default_timeout_ms),
       configured: %{},
       owners: %{},
       pending: :queue.new()
     }}
  end

  @impl GenServer
  def handle_call({:run, owner, segment_id, version, configuration, request}, from, state) do
    state = watch(state, owner, segment_id)

    case ensure_port(state) do
      {:ok, state} ->
        state =
          if Map.get(state.configured, segment_id) == version,
            do: state,
            else:
              state
              |> send_request(configuration, {:configure, segment_id})
              |> put_in([:configured, segment_id], version)

        {:noreply, send_request(state, request, {:run, from})}

      {:error, reason, state} ->
        {:reply, {:error, reason}, state}
    end
  end

  # Each request waits in `pending`, in the order sent, with its deadline.
  defp send_request(%{port: port} = state, request, waiting) do
    Port.command(port, request)
    deadline = make_ref()
    timer = Process.send_after(self(), {:deadline, deadline}, state.timeout_ms)
    %{state | pending: :queue.in({waiting, deadline, timer}, state.pending)}
  end

  @impl GenServer
  def handle_info({port, {:data, <<@log_tag, level, message::binary>>}}, %{port: port} = state) do
    log(level, message)
    {:noreply, state}
  end

  def handle_info({port, {:data, reply}}, %{port: port} = state) do
    case :queue.out(state.pending) do
      {{:value, {waiting, _deadline, timer}}, pending} ->
        Process.cancel_timer(timer)
        {:noreply, answer(waiting, reply, %{state | pending: pending})}

      {:empty, _pending} ->
        {:noreply, state}
    end
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    Logger.warning("#{__MODULE__}: stereo_match exited with #{status}")
    {:noreply, closed(state, {:exited, status})}
  end

  def handle_info({:deadline, deadline}, state) do
    if Enum.any?(:queue.to_list(state.pending), &match?({_waiting, ^deadline, _timer}, &1)) do
      Port.close(state.port)
      {:noreply, closed(state, :timeout)}
    else
      {:noreply, state}
    end
  end

  def handle_info({:DOWN, _ref, :process, owner, _reason}, state) do
    {segments, owners} = Map.pop(state.owners, owner, MapSet.new())

    # The Port may have exited without its exit status handled yet.
    for segment_id <- segments,
        Map.has_key?(state.configured, segment_id),
        Port.info(state.port) != nil,
        do: Port.command(state.port, <<@release, segment_id::little-32>>)

    configured = Map.drop(state.configured, Enum.to_list(segments))
    {:noreply, %{state | owners: owners, configured: configured}}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp answer({:configure, _segment_id}, <<@configured_tag, _rest::binary>>, state), do: state

  # The run sent with it fails too, rather than run on the configuration before.
  defp answer({:configure, segment_id}, _refused, state) do
    pending =
      case :queue.out(state.pending) do
        {{:value, {{:run, from}, deadline, timer}}, pending} ->
          :queue.in_r({{:refused, from}, deadline, timer}, pending)

        {:empty, pending} ->
          pending
      end

    %{state | configured: Map.delete(state.configured, segment_id), pending: pending}
  end

  defp answer({:run, from}, <<@outputs_tag, reply::binary>>, state) do
    GenServer.reply(from, {:ok, reply})
    state
  end

  defp answer({_run_or_refused, from}, _refused, state) do
    GenServer.reply(from, {:error, :bad_request})
    state
  end

  defp closed(state, reason) do
    for {{kind, from}, _deadline, timer} <- :queue.to_list(state.pending) do
      Process.cancel_timer(timer)
      if kind in [:run, :refused], do: GenServer.reply(from, {:error, reason})
    end

    %{state | port: nil, configured: %{}, pending: :queue.new()}
  end

  defp watch(state, owner, segment_id) do
    case state.owners do
      %{^owner => segments} ->
        put_in(state.owners[owner], MapSet.put(segments, segment_id))

      _other ->
        Process.monitor(owner)
        put_in(state.owners[owner], MapSet.new([segment_id]))
    end
  end

  defp log(level, message),
    do: Logger.log(log_level(level), "#{__MODULE__} stereo_match: #{message}")

  defp log_level(0), do: :info
  defp log_level(1), do: :warning
  defp log_level(_level), do: :error

  defp ensure_port(%{port: nil} = state) do
    path = executable()

    if File.exists?(path) do
      options = [:binary, {:packet, 4}, :exit_status, args: arguments()]
      {:ok, %{state | port: Port.open({:spawn_executable, path}, options)}}
    else
      {:error, {:no_matcher, path}, state}
    end
  end

  defp ensure_port(state), do: {:ok, state}

  defp arguments do
    case Application.get_env(:vision_core, :stereo_match_threads) do
      nil -> []
      threads -> ["--threads", Integer.to_string(threads)]
    end
  end

  defp executable do
    Application.get_env(:vision_core, :stereo_match_path) ||
      Path.join(List.to_string(:code.priv_dir(:vision_core)), "stereo_match")
  end
end
