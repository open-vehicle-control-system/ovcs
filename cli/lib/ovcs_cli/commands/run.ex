defmodule OvcsCli.Commands.Run do
  @moduledoc """
  Boot the whole vehicle locally in one BEAM.

  Runs `ovcs can setup <vehicle>` first, then spawns `iex -S mix`
  inside the vehicle's Mix project. The vehicle package's
  `Application` (opt-in per vehicle, e.g. `Ovcs1.Application`)
  starts VMS + infotainment endpoints + any host-compatible
  bridges declared in `bridge_firmwares/0`.
  """

  alias OvcsCli.Shell

  def run(repo_root, vehicle_dir) do
    Shell.exec!("./ovcs can setup #{vehicle_dir}")

    IO.puts("")
    IO.puts(IO.ANSI.bright() <> "Booting vehicle locally…" <> IO.ANSI.reset())

    exec_interactive!(
      "sh -c 'cd #{shell_quote(Path.join([repo_root, "vehicles", vehicle_dir]))} && exec iex -S mix'"
    )
  end

  # Like `Shell.exec!` but the spawned child inherits the parent's
  # tty (stdin/stdout/stderr) so iex can run interactively. Port
  # still receives `{:exit_status, code}` via the control channel.
  defp exec_interactive!(cmd) do
    IO.puts(IO.ANSI.cyan() <> "→ #{cmd}" <> IO.ANSI.reset())
    port = Port.open({:spawn, cmd}, [:nouse_stdio, :exit_status])

    receive do
      {^port, {:exit_status, 0}} -> :ok
      {^port, {:exit_status, code}} -> System.halt(code)
    end
  end

  defp shell_quote(s), do: "'" <> String.replace(s, "'", "'\\''") <> "'"
end
