defmodule SSHSubsystemFwup.FwupPort do
  require Logger

  @moduledoc false

  # Caller must     Process.flag(:trap_exit, true)

  @spec open_port(SSHSubsystemFwup.options()) :: port()
  def open_port(options) do
    fwup_path = options[:fwup_path]
    fwup_env = env_to_charlist(options[:fwup_env])
    fwup_extra_options = options[:fwup_extra_options]
    devpath = options[:devpath]
    task = options[:task]

    args = [
      "--exit-handshake",
      "--apply",
      "--no-unmount",
      "-d",
      devpath,
      "--task",
      task | fwup_extra_options
    ]

    Port.open({:spawn_executable, fwup_path}, [
      {:args, args},
      {:env, fwup_env},
      :use_stdio,
      :binary
    ])
  end

  defp env_to_charlist(env) do
    for {k, v} <- env do
      {to_charlist(k), to_charlist(v)}
    end
  end

  @spec send_data(port(), binary()) :: :ok
  def send_data(port, data) do
    # Since fwup may be slower than ssh, we need to provide backpressure
    # here. It's tricky since `Port.command/2` is the only way to send
    # bytes to fwup synchronously, but it's possible for fwup to error
    # out when it's sending. If fwup errors out, then we need to make
    # sure that a message gets back to the user for what happened.
    # `Port.command/2` exits on error (it will be an :epipe error).
    # Therefore we start a new process to call `Port.command/2` while
    # we continue to handle responses. We also trap_exit to get messages
    # when the port the Task exit.

    Port.command(port, data)
    :ok
  rescue
    ArgumentError ->
      Logger.info("Port.command ArgumentError race condition detected and handled")
  end

  @spec handle_port(port(), any()) :: {:respond, binary()} | {:done, binary(), non_neg_integer()}
  def handle_port(port, {:data, response}) do
    # fwup says that it's going to exit by sending a CTRL+Z (0x1a)
    case String.split(response, "\x1a", parts: 2) do
      [response] ->
        {:respond, response}

      [response, <<status>>] ->
        # fwup exited with status
        close_port(port)
        {:done, response, status}

      [response, other] ->
        # fwup exited without status
        Logger.info("fwup exited improperly: #{inspect(other)}")
        close_port(port)
        {:done, response, 0}
    end
  end

  def handle_port(_port, :closed) do
    Logger.info("fwup port was closed")
    {:done, "", 0}
  end

  defp close_port(port) do
    send(port, {self(), :close})
  end
end
