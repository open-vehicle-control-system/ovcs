defmodule OvcsCli.Shell do
  @moduledoc "Thin wrapper for `System.cmd/3` with env-merging and streamed output."

  @doc """
  Runs `cmd` in `dir` with the given extra env vars merged on top of the
  current process environment. Streams stdout/stderr live. Exits with the
  subprocess's exit code on failure so the escript propagates it.
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
