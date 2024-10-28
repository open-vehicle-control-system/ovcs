# SPDX-FileCopyrightText: 2017 Nerves Project Developers
#
# SPDX-License-Identifier: Apache-2.0

defmodule NervesLogging.SyslogTailer do
  @moduledoc """
  This GenServer routes syslog messages from C-based applications and libraries through
  the Elixir Logger for collection.
  """

  use GenServer

  alias NervesLogging.SyslogParser
  require Logger

  @syslog_path "/dev/log"

  @doc """
  Start the local syslog GenServer.
  """
  @spec start_link(any()) :: GenServer.on_start()
  def start_link(_args) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @impl GenServer
  def init(_args) do
    # Blindly try to remove an old file just in case it exists from a previous run
    _ = File.rm(@syslog_path)

    case :gen_udp.open(0, [:local, :binary, {:active, true}, {:ip, {:local, @syslog_path}}]) do
      {:ok, log_port} ->
        # All processes should be able to log messages
        File.chmod!(@syslog_path, 0o666)

        {:ok, log_port}

      {:error, reason} ->
        Logger.error("nerves_logger: not starting syslog server due to #{inspect(reason)}")
        :ignore
    end
  end

  @impl GenServer
  def handle_info({:udp, log_port, _, 0, raw_entry}, log_port) do
    case SyslogParser.parse(raw_entry) do
      {:ok, %{facility: facility, severity: severity, message: message}} ->
        Logger.bare_log(
          severity,
          message,
          application: :"$syslog",
          module: __MODULE__,
          facility: facility
        )

      _ ->
        # This is unlikely to ever happen, but if a message was somehow
        # malformed and we couldn't parse the syslog priority, we should
        # still do a best-effort to pass along the raw data.
        Logger.warning("Malformed syslog report: #{inspect(raw_entry)}")
    end

    {:noreply, log_port}
  end

  def handle_info(_, state), do: {:noreply, state}
end
