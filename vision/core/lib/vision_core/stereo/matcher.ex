defmodule VisionCore.Stereo.Matcher do
  @moduledoc """
  The `stereo_match` Port, which computes the stereo stages natively on
  every core of a CPU, for the `VisionCore.Stereo.NativeSegment`s of
  every pipeline. The Port holds each segment's state: what its stages
  carry from one pair to the next and what depends on their settings
  alone. Requests are computed one at a time, in the order they arrive,
  but need not wait for the previous reply: the Port reads a request
  while it computes the one before, and writes a reply while it computes
  the next. `send_run/6` sends one without waiting.

  A segment is configured on its first pair, and again once its version
  changes (a calibration reload) or the Port has restarted, which loses
  every segment's state. A segment is released when the process that
  ran it exits.

  The Port opens on the first request and reopens after it exits. A
  request without a reply within `:timeout_ms` of being sent closes the
  Port, failing every request still waiting, so a late reply cannot
  answer another one. The Port's log lines go to the `Logger`.

  ## Options

    * `:name` (`VisionCore.Stereo.Matcher`) — the server's name.
    * `:path` (`priv/stereo_match`) — the `stereo_match` binary.
    * `:threads` (one per core) — how many threads it computes on, a
      positive integer.
    * `:timeout_ms` (`5000`) — how long a request may wait for its reply.

  `VisionCore.Application` starts it with `config :vision_core,
  :stereo_match_path` and `:stereo_match_threads`.
  """
  use GenServer
  require Logger

  @default_timeout_ms 5_000
  @log_tag 2
  @configured_tag 7
  @outputs_tag 8
  @refused_tag 9
  @release 3

  @doc "Starts the matcher server; see the module doc for `opts`."
  def start_link(opts \\ []),
    do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  @doc """
  Sends `request` to `matcher`, to run on segment `segment_id`, first
  configuring it with `configuration` unless the Port has it at
  `version`, without waiting: the caller receives the reply as a message
  that `:gen_server.check_response/2` recognises from the returned
  request id: `{:ok, payload}`; `{:error, {:configuration_refused,
  reason}}` when the Port refuses the configuration, saying why; or
  `{:error, :bad_request}` when it refuses the run, having logged why.
  Requests a process sends are computed in the order it sends them. The
  segment is released once `owner` exits. The protocol is the Port's;
  see `VisionCore.Stereo.NativeSegment`.
  """
  @spec send_run(
          GenServer.server(),
          pid(),
          non_neg_integer(),
          non_neg_integer(),
          iodata(),
          iodata()
        ) :: :gen_server.request_id()
  def send_run(matcher, owner, segment_id, version, configuration, request),
    do:
      :gen_server.send_request(
        matcher,
        {:run, owner, segment_id, version, configuration, request}
      )

  @impl GenServer
  def init(opts) do
    {:ok,
     %{
       port: nil,
       path: Keyword.get(opts, :path) || default_path(),
       arguments: port_arguments(Keyword.get(opts, :threads)),
       timeout_ms: Keyword.get(opts, :timeout_ms, @default_timeout_ms),
       configured: %{},
       refused: MapSet.new(),
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

        {:noreply, send_request(state, request, {:run, segment_id, from})}

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
    refused = MapSet.difference(state.refused, segments)
    {:noreply, %{state | owners: owners, configured: configured, refused: refused}}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp answer({:configure, segment_id}, <<@configured_tag, _rest::binary>>, state),
    do: %{state | refused: MapSet.delete(state.refused, segment_id)}

  # The run sent with it fails too, rather than run on the configuration before.
  defp answer({:configure, segment_id}, refused, state) do
    {error, state} =
      case refusal(refused, :error) do
        nil ->
          {:bad_request, state}

        reason ->
          {{:configuration_refused, reason},
           %{state | refused: MapSet.put(state.refused, segment_id)}}
      end

    pending =
      case :queue.out(state.pending) do
        {{:value, {{:run, _segment_id, from}, deadline, timer}}, pending} ->
          :queue.in_r({{:failed, from, error}, deadline, timer}, pending)

        {:empty, pending} ->
          pending
      end

    %{state | configured: Map.delete(state.configured, segment_id), pending: pending}
  end

  defp answer({:run, _segment_id, from}, <<@outputs_tag, reply::binary>>, state) do
    GenServer.reply(from, {:ok, reply})
    state
  end

  defp answer({:failed, from, error}, _reply, state) do
    GenServer.reply(from, {:error, error})
    state
  end

  # A run sent before its segment's configuration was refused fails for that, logged already.
  defp answer({:run, segment_id, from}, refused, state) do
    refusal(refused, if(MapSet.member?(state.refused, segment_id), do: :debug, else: :error))
    GenServer.reply(from, {:error, :bad_request})
    state
  end

  # Why the Port refused a request, logged at `level` like its log lines; `nil` for another reply.
  defp refusal(<<@refused_tag, reason::binary>>, level) do
    Logger.log(level, "#{__MODULE__} stereo_match: #{reason}")
    reason
  end

  defp refusal(_reply, _level), do: nil

  defp closed(state, reason) do
    for {waiting, _deadline, timer} <- :queue.to_list(state.pending) do
      Process.cancel_timer(timer)
      fail(waiting, reason)
    end

    %{state | port: nil, configured: %{}, refused: MapSet.new(), pending: :queue.new()}
  end

  # A run the Port no longer answers fails with `reason`, unless it had failed already.
  defp fail({:run, _segment_id, from}, reason), do: GenServer.reply(from, {:error, reason})
  defp fail({:failed, from, error}, _reason), do: GenServer.reply(from, {:error, error})
  defp fail({:configure, _segment_id}, _reason), do: :ok

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

  defp ensure_port(%{port: nil, path: path} = state) do
    if File.exists?(path) do
      options = [:binary, {:packet, 4}, :exit_status, args: state.arguments]
      {:ok, %{state | port: Port.open({:spawn_executable, path}, options)}}
    else
      {:error, {:no_matcher, path}, state}
    end
  end

  # A Port that has exited, its exit status not handled yet, cannot be written to.
  defp ensure_port(%{port: port} = state) do
    if Port.info(port), do: {:ok, state}, else: state |> closed(:exited) |> ensure_port()
  end

  @doc false
  def port_arguments(nil), do: []

  def port_arguments(threads) when is_integer(threads) and threads > 0,
    do: ["--threads", Integer.to_string(threads)]

  def port_arguments(threads) do
    Logger.warning(
      "#{__MODULE__}: :threads (config :vision_core, :stereo_match_threads) must be a " <>
        "positive integer, got #{inspect(threads)}; computing on one thread per core"
    )

    []
  end

  defp default_path, do: Path.join(List.to_string(:code.priv_dir(:vision_core)), "stereo_match")
end
