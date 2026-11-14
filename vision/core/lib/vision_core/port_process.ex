defmodule VisionCore.PortProcess do
  @moduledoc """
  Closes a Port and makes sure its program goes with it.

  Closing a Port closes the program's stdin and stdout, which a program
  reading its stdin takes as its end. A program wedged elsewhere, as in
  a call to an accelerator that never returns, does not see it and
  would live on, holding its device and its memory. `close/2` therefore
  kills the program once a grace has passed, unless it has exited.
  """
  require Logger

  @default_grace_ms 500

  @doc """
  Closes `port` and, `grace_ms` (500) later, kills its program if it
  still runs. A Port already closed is left alone.
  """
  @spec close(port(), non_neg_integer()) :: :ok
  def close(port, grace_ms \\ @default_grace_ms) do
    case os_pid(port) do
      nil ->
        :ok

      os_pid ->
        close_port(port)
        kill_after(os_pid, grace_ms)
    end
  end

  @doc """
  Kills the program `os_pid`, `grace_ms` (500) later, if it still runs:
  for a Port that died under a program which did not exit with it.
  """
  @spec kill_after(non_neg_integer() | nil, non_neg_integer()) :: :ok
  def kill_after(os_pid, grace_ms \\ @default_grace_ms)
  def kill_after(nil, _grace_ms), do: :ok

  def kill_after(os_pid, grace_ms) do
    {:ok, _timer} = :timer.apply_after(grace_ms, __MODULE__, :kill, [os_pid])
    :ok
  end

  @doc "The operating system's id of `port`'s program, `nil` for a Port that is closed."
  @spec os_pid(port()) :: non_neg_integer() | nil
  def os_pid(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, os_pid} when is_integer(os_pid) -> os_pid
      _closed -> nil
    end
  end

  @doc "Whether the program `os_pid` still runs: a program that exited and is not yet reaped does not."
  @spec alive?(non_neg_integer()) :: boolean()
  def alive?(os_pid) do
    case File.read("/proc/#{os_pid}/stat") do
      # The state follows the command name, which is in parentheses and may hold spaces.
      {:ok, stat} -> stat |> String.split(") ", parts: 2) |> List.last() |> String.first() != "Z"
      {:error, _reason} -> false
    end
  end

  @doc "Kills the program `os_pid` if it still runs."
  @spec kill(non_neg_integer()) :: :ok
  def kill(os_pid) do
    if alive?(os_pid) do
      Logger.warning("#{inspect(__MODULE__)}: program #{os_pid} outlived its Port, killing it")
      System.cmd("kill", ["-KILL", Integer.to_string(os_pid)], stderr_to_stdout: true)
    end

    :ok
  end

  # The program may exit, closing the Port, between the id read and the close.
  defp close_port(port) do
    Port.close(port)
  rescue
    ArgumentError -> :ok
  end
end
