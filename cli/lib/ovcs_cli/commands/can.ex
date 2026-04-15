defmodule OvcsCli.Commands.Can do
  @moduledoc """
  Host-side CAN helper commands. Currently:

    ovcs can setup <vehicle>

  Reads the vehicle's default_can_mapping(:host) on both sides, figures
  out which virtual CAN interfaces it needs, and brings them up. The
  action is idempotent: interfaces that already exist and are UP are
  skipped, so re-running is a no-op and no sudo prompt fires unless
  there's actual work to do.
  """

  alias OvcsCli.Vehicles

  def setup(repo_root, vehicle_dir) do
    vehicle = find_vehicle!(repo_root, vehicle_dir)
    interfaces = Vehicles.host_can_interfaces(vehicle)

    if interfaces == [] do
      IO.puts(
        IO.ANSI.yellow() <>
          "No host CAN interfaces declared by #{vehicle.module}.default_can_mapping(:host)." <>
          IO.ANSI.reset()
      )
      System.halt(0)
    end

    IO.puts(IO.ANSI.bright() <> "#{vehicle.module} requires:" <> IO.ANSI.reset())
    Enum.each(interfaces, &IO.puts("  - #{&1}"))

    actions = plan_actions(interfaces)

    if actions == [] do
      IO.puts("")
      IO.puts(IO.ANSI.green() <> "All up — nothing to do." <> IO.ANSI.reset())
      System.halt(0)
    end

    IO.puts("")
    IO.puts(IO.ANSI.bright() <> "Will run as root:" <> IO.ANSI.reset())
    Enum.each(actions, &IO.puts("  - #{&1}"))

    apply_actions!(interfaces)

    IO.puts("")
    IO.puts(IO.ANSI.green() <> "Done." <> IO.ANSI.reset())
  end

  defp find_vehicle!(repo_root, vehicle_dir) do
    case Enum.find(Vehicles.list(repo_root), &(&1.dir == vehicle_dir)) do
      nil -> raise "Unknown vehicle #{inspect(vehicle_dir)}"
      v -> v
    end
  end

  defp plan_actions(interfaces) do
    module_action =
      if vcan_module_loaded?(), do: [], else: ["load vcan module"]

    iface_actions =
      Enum.flat_map(interfaces, fn iface ->
        cond do
          !iface_exists?(iface) -> ["create #{iface}"]
          !iface_up?(iface) -> ["bring up #{iface}"]
          true -> []
        end
      end)

    module_action ++ iface_actions
  end

  defp vcan_module_loaded? do
    case System.cmd("sh", ["-c", "lsmod | awk '{print $1}' | grep -qx vcan"], stderr_to_stdout: true) do
      {_, 0} -> true
      _ -> false
    end
  end

  defp iface_exists?(iface) do
    case System.cmd("ip", ["link", "show", iface], stderr_to_stdout: true) do
      {_, 0} -> true
      _ -> false
    end
  end

  defp iface_up?(iface) do
    case System.cmd("sh", ["-c", "ip -br link show #{iface} | awk '{print $2}'"], stderr_to_stdout: true) do
      {output, 0} -> String.trim(output) == "UP"
      _ -> false
    end
  end

  defp apply_actions!(interfaces) do
    list = Enum.join(interfaces, " ")

    script = """
    set -e
    if ! lsmod | awk '{print $1}' | grep -qx vcan; then
      modprobe vcan
    fi
    for iface in #{list}; do
      if ! ip link show "$iface" >/dev/null 2>&1; then
        ip link add dev "$iface" type vcan
      fi
      ip link set up "$iface"
    done
    """

    OvcsCli.Shell.exec!("sudo bash -c #{shell_quote(script)}")
  end

  defp shell_quote(s), do: "'" <> String.replace(s, "'", "'\\''") <> "'"
end
