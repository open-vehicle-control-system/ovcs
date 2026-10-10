defmodule OvcsBus.Distribution do
  @moduledoc """
  Starts Erlang distribution on a deployed Nerves firmware.

  Nerves releases boot without a node name (`nerves_pack` leaves
  distribution to the application), so each firmware opts in through
  its target config:

      config :ovcs_bus, :distribution, domain: "local"

  With that set, `ensure_started/0` runs `epmd -daemon` and starts the
  node as `nerves@<hostname>.<domain>` with long names, where
  `<hostname>` is the device hostname erlinit sets from
  `hostname_pattern` (`<vehicle>-<role>`). The cookie is the release
  cookie, passed to the VM as `-setcookie` in `rel/vm.args.eex`.

  A long name is used because Erlang's resolver on Nerves has no search
  domain: a short peer name like `nerves@ovcs1-vms` does not resolve,
  while `nerves@ovcs1-vms.local` does once mdns_lite's DNS bridge is
  the first name server (see each firmware's `:mdns_lite` and
  `:vintage_net` config).

  Without the `:distribution` config (host runs, where `./ovcs run`
  passes `--sname` and `--cookie`) it does nothing.

  Starting distribution needs neither an IP address nor a reachable
  peer, so it succeeds before the network is up. A failure is logged
  and returned; `OvcsBus.Cluster` calls this on every tick, so the next
  tick retries.
  """
  require Logger

  @sname "nerves"

  @spec ensure_started() :: :ok | :disabled | {:error, term()}
  def ensure_started do
    case Application.get_env(:ovcs_bus, :distribution) do
      nil -> :disabled
      opts -> if Node.alive?(), do: :ok, else: start(opts)
    end
  end

  defp start(opts) do
    domain = Keyword.fetch!(opts, :domain)
    {:ok, hostname} = :inet.gethostname()
    name = String.to_atom("#{@sname}@#{hostname}.#{domain}")

    with :ok <- start_epmd(),
         {:ok, _pid} <- Node.start(name, name_domain: :longnames) do
      Logger.info("OvcsBus.Distribution started as #{inspect(Node.self())}")
      :ok
    else
      {:error, reason} = error ->
        Logger.warning("OvcsBus.Distribution could not start #{name}: #{inspect(reason)}")
        error
    end
  end

  # `epmd -daemon` returns immediately and is a no-op when epmd is
  # already running.
  defp start_epmd do
    case System.cmd("epmd", ["-daemon"], stderr_to_stdout: true) do
      {_, 0} -> :ok
      {out, status} -> {:error, {:epmd, status, out}}
    end
  rescue
    e in ErlangError -> {:error, {:epmd, e.original}}
  end
end
