defmodule OvcsCli.Commands.Vehicles do
  @moduledoc "List discovered vehicles and their Nerves targets per side."

  alias OvcsCli.Vehicles

  def run(_repo_root, vehicles) do
    IO.puts(IO.ANSI.bright() <> "Discovered vehicles:" <> IO.ANSI.reset())
    IO.puts("")

    Enum.each(vehicles, fn v ->
      IO.puts("  #{IO.ANSI.cyan()}#{v.dir}#{IO.ANSI.reset()}  (#{v.module})")
      vms = Vehicles.nerves_target(v, :vms) || "—"
      info = Vehicles.nerves_target(v, :infotainment) || "—"
      IO.puts("    vms          → #{vms}")
      IO.puts("    infotainment → #{info}")
    end)

    IO.puts("")
  end
end
