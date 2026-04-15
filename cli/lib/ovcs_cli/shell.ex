defmodule OvcsCli.Shell do
  @moduledoc "Thin subprocess wrapper with env-merging and live output."

  @doc """
  Runs `cmd` in `dir` with the given extra env vars. Streams stdout/stderr
  live and captures them. Exits with the subprocess's exit code on failure.

  Not suitable for interactive processes (`sudo`, REPLs) because the
  parent's tty is detached. Use `exec!/1` for those.
  """
  def run!(cmd, dir: dir, env: env) when is_binary(cmd) and is_map(env) do
    IO.puts(IO.ANSI.cyan() <> "→ #{cmd}" <> IO.ANSI.reset() <> IO.ANSI.faint() <> "  (cd #{dir})" <> IO.ANSI.reset())

    port =
      Port.open({:spawn, cmd}, [
        :binary,
        :exit_status,
        :use_stdio,
        :stderr_to_stdout,
        cd: dir,
        env: Enum.map(env, fn {k, v} -> {String.to_charlist(k), String.to_charlist(v)} end)
      ])

    await_exit(port)
  end

  @doc """
  Runs `cmd` connected directly to the user's tty (stdin inherited), so
  prompts from `sudo`, `ssh`, etc. reach the user. Output is not captured
  — it's written straight to the terminal.
  """
  def exec!(cmd) when is_binary(cmd) do
    IO.puts(IO.ANSI.cyan() <> "→ #{cmd}" <> IO.ANSI.reset())

    port = Port.open({:spawn, cmd}, [:nouse_stdio, :exit_status])
    await_exit(port)
  end

  defp await_exit(port) do
    receive do
      {^port, {:data, chunk}} ->
        IO.write(chunk)
        await_exit(port)

      {^port, {:exit_status, 0}} ->
        :ok

      {^port, {:exit_status, code}} ->
        IO.puts(IO.ANSI.red() <> "✗ exited with #{code}" <> IO.ANSI.reset())
        System.halt(code)
    end
  end
end
