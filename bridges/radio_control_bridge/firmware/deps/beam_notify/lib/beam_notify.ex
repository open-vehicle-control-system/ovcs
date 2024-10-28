defmodule BEAMNotify do
  @moduledoc """
  Send a message to the BEAM from a shell script
  """
  use GenServer

  require Logger

  @typedoc """
  Callback for dispatching notifications

  BEAMNotify calls the dispatcher function whenever a message comes in. The
  first parameter is the list of arguments passed to `$BEAM_NOTIFY`. The
  second argument is a map containing environment variables. Whether or
  not the map is populated depends on the options to `start_link/1`.
  """
  @type dispatcher() :: ([String.t()], %{String.t() => String.t()} -> :ok)

  @typedoc """
  BEAMNotify takes the following options

  * `:name` - a unique name for this notifier. This is required if you expect
    to run multiple BEAMNotify GenServers at a time.
  * `:dispatcher` - a function to call when a notification comes in
  * `:path` - the path to use for the named socket. A path in the system
     temporary directory is the default.
  * `:mode` - the permissions to apply to the socket. Should be an octal number
     eg: 0o660 for read/write owner/group, no access to everyone else
  * `:report_env` - set to `true` to report environment variables in addition
     to commandline argument. Defaults to `false`
  * `:recbuf` - receive buffer size. If you're sending a particular large
     amount of data and getting errors from `:erlang.binary_to_term(data)`, try
     making this bigger. Defaults to 8192.
  """
  @type options() :: [
          name: binary() | atom(),
          path: Path.t(),
          mode: non_neg_integer(),
          dispatcher: dispatcher(),
          report_env: boolean(),
          recbuf: non_neg_integer()
        ]

  @doc """
  Start the BEAMNotify message receiver
  """
  @spec start_link(options()) :: GenServer.on_start()
  def start_link(options) do
    name = options |> name_from_options() |> gen_server_name()
    GenServer.start_link(__MODULE__, options, name: name)
  end

  @doc """
  Return the OS environment needed to call `$BEAM_NOTIFY`

  This returns a map that can be passed directly to `System.cmd/3` via its
  `:env` option.

  This function can be passed different things based on what's convenient.

  1. If you're setting up `child_spec`'s for a supervision tree and need the
     environment to pass in another `child_spec`, call this with the same
     options that you'd pass to `start_link/1`. This is a very common use.

  2. If you called `start_link/1` manually and have the pid, call it with
     the pid.

  3. If you only have the name that was passed to `start_link/1`, then call
     it with the name. The name alone is insufficient for returning the
     `$BEAM_NOTIFY_OPTIONS` environment variable, so the `BEAMNotify`
     GenServer must be running. If you're in a chicken-and-egg situation
     where you're setting up a supervision tree, but it hasn't been started
     yet, see option 1.
  """
  @spec env(pid() | binary() | atom() | keyword()) :: Enumerable.t()
  def env(options) when is_list(options) do
    options_to_env(options)
  end

  def env(pid) when is_pid(pid) do
    GenServer.call(pid, :env)
  end

  def env(name) when is_binary(name) or is_atom(name) do
    GenServer.call(gen_server_name(name), :env)
  end

  @doc """
  Return the path to `beam_notify`
  """
  @spec bin_path() :: Path.t()
  def bin_path() do
    Application.app_dir(:beam_notify, ["priv", "beam_notify"])
  end

  @impl GenServer
  def init(options) do
    socket_path = socket_path(options)
    dispatcher = Keyword.get(options, :dispatcher, &null_dispatcher/2)
    recbuf = Keyword.get(options, :recbuf, 8192)
    mode = Keyword.get(options, :mode)

    # Blindly try to remove an old file just in case it exists from a previous run
    _ = File.rm(socket_path)
    _ = File.mkdir_p(Path.dirname(socket_path))

    {:ok, socket} =
      :gen_udp.open(0, [
        :local,
        :binary,
        {:active, true},
        {:ip, {:local, socket_path}},
        {:recbuf, recbuf}
      ])

    if mode, do: File.chmod!(socket_path, mode)

    state = %{
      socket_path: socket_path,
      socket: socket,
      options: options,
      dispatcher: dispatcher
    }

    {:ok, state}
  end

  @impl GenServer
  def handle_call(:env, _from, state) do
    {:reply, options_to_env(state.options), state}
  end

  @impl GenServer
  def handle_info({:udp, socket, _, 0, data}, %{socket: socket} = state) do
    {args, env} = :erlang.binary_to_term(data)

    state.dispatcher.(args, env)

    {:noreply, state}
  end

  @impl GenServer
  def terminate(_reason, state) do
    # Try to clean up
    _ = File.rm(state.socket_path)
  end

  defp gen_server_name(name) do
    Module.concat(__MODULE__, name)
  end

  defp name_from_options(options) do
    Keyword.get(options, :name, :unnamed)
  end

  defp null_dispatcher(args, env) do
    Logger.warning("beam_notify called with no dispatcher: #{inspect(args)}, #{inspect(env)}")
  end

  defp options_to_env(options) do
    bn_options = options_to_cmdline(options) |> Enum.map_join(" ", &quote_string/1)
    %{"BEAM_NOTIFY" => bin_path(), "BEAM_NOTIFY_OPTIONS" => bn_options}
  end

  defp options_to_cmdline(options) do
    ["-p", socket_path(options)] ++ report_env_arg(options)
  end

  defp report_env_arg(options) do
    if Keyword.get(options, :report_env) do
      ["-e"]
    else
      []
    end
  end

  defp quote_string(s) do
    if String.contains?(s, " ") do
      "\"" <> s <> "\""
    else
      s
    end
  end

  defp socket_path(options) do
    case Keyword.get(options, :path) do
      nil ->
        safe_name = name_from_options(options) |> :erlang.phash2() |> Integer.to_string()
        name = "beam_notify-" <> safe_name
        Path.join(System.tmp_dir!(), name)

      path ->
        path
    end
  end
end
