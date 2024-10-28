# SPDX-FileCopyrightText: 2017 Nerves Project Developers
#
# SPDX-License-Identifier: Apache-2.0

defmodule NervesLogging.KmsgTailer do
  @moduledoc """
  Collects operating system-level messages from `/proc/kmsg`,
  forwarding them to `Logger` with an appropriate level to match the syslog
  priority parsed out of the message.
  """

  use GenServer

  alias NervesLogging.KmsgParser
  require Logger

  @doc """
  Start the kmsg monitoring GenServer.
  """
  @spec start_link(any()) :: GenServer.on_start()
  def start_link(_args) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @impl GenServer
  def init(_args) do
    executable = Application.app_dir(:nerves_logging, ["priv", "kmsg_tailer"])

    port =
      Port.open({:spawn_executable, executable}, [
        {:line, 1024},
        :use_stdio,
        :binary,
        :exit_status
      ])

    {:ok, %{port: port, buffer: ""}}
  end

  @impl GenServer
  def handle_info({port, {:data, {:noeol, fragment}}}, %{port: port, buffer: buffer} = state) do
    {:noreply, %{state | buffer: buffer <> fragment}}
  end

  def handle_info(
        {port, {:data, {:eol, fragment}}},
        %{port: port, buffer: buffer} = state
      ) do
    handle_message(buffer <> fragment)
    {:noreply, %{state | buffer: ""}}
  end

  def handle_info(_, state), do: {:noreply, state}

  defp handle_message(raw_entry) do
    case KmsgParser.parse(raw_entry) do
      {:ok, %{facility: facility, severity: severity, message: message}} ->
        Logger.bare_log(
          severity,
          message,
          application: :"$kmsg",
          module: __MODULE__,
          facility: facility
        )

      _ ->
        # We don't handle continuations and multi-line kmsg logs.

        # It's painful to ignore log messages, but these don't seem
        # to be reported by dmesg and the ones I've seen so far contain
        # redundant information that's primary value is that it's
        # machine parsable (i.e. key=value listings)
        :ok
    end
  end
end
