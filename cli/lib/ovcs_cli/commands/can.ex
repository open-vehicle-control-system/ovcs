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

  def status(repo_root, vehicle_dir) do
    vehicle = find_vehicle!(repo_root, vehicle_dir)
    interfaces = Vehicles.host_can_interfaces(vehicle)

    if interfaces == [] do
      IO.puts(
        IO.ANSI.yellow() <>
          "No host CAN interfaces declared by #{vehicle.module}." <>
          IO.ANSI.reset()
      )
      System.halt(0)
    end

    IO.puts(IO.ANSI.bright() <> "#{vehicle.module} host CAN interfaces:" <> IO.ANSI.reset())

    missing =
      Enum.reduce(interfaces, 0, fn iface, acc ->
        cond do
          !iface_exists?(iface) ->
            IO.puts("  #{IO.ANSI.red()}✗#{IO.ANSI.reset()} #{iface}  #{IO.ANSI.faint()}not created#{IO.ANSI.reset()}")
            acc + 1

          !iface_up?(iface) ->
            IO.puts("  #{IO.ANSI.yellow()}⚠#{IO.ANSI.reset()} #{iface}  #{IO.ANSI.faint()}down#{IO.ANSI.reset()}")
            acc + 1

          true ->
            IO.puts("  #{IO.ANSI.green()}✓#{IO.ANSI.reset()} #{iface}  #{IO.ANSI.faint()}up#{IO.ANSI.reset()}")
            acc
        end
      end)

    IO.puts("")

    if missing == 0 do
      IO.puts(IO.ANSI.green() <> "All interfaces up." <> IO.ANSI.reset())
      System.halt(0)
    else
      IO.puts(IO.ANSI.yellow() <> "#{missing} interface(s) missing or down." <> IO.ANSI.reset())
      IO.puts(IO.ANSI.faint() <> "Run: ovcs can setup #{vehicle.dir}" <> IO.ANSI.reset())
      System.halt(1)
    end
  end

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

    actions = plan_actions(interfaces)

    if actions == [] do
      IO.puts(IO.ANSI.green() <> "All virtual CAN interfaces for #{vehicle.module} are already up — nothing to do." <> IO.ANSI.reset())
      System.halt(0)
    end

    IO.puts(IO.ANSI.bright() <> "#{vehicle.module} requires:" <> IO.ANSI.reset())
    Enum.each(interfaces, &IO.puts("  - #{&1}"))

    IO.puts("")
    IO.puts(IO.ANSI.bright() <> "Will run as root:" <> IO.ANSI.reset())
    Enum.each(actions, &IO.puts("  - #{&1}"))

    apply_actions!(interfaces)
    print_summary(vehicle, interfaces)
  end

  defp print_summary(vehicle, interfaces) do
    IO.puts("")
    IO.puts(IO.ANSI.bright() <> "Virtual CAN interfaces ready for #{vehicle.module}:" <> IO.ANSI.reset())

    Enum.each(interfaces, fn iface ->
      state = iface_state_label(iface)
      IO.puts("  #{IO.ANSI.green()}✓#{IO.ANSI.reset()} #{iface}  #{IO.ANSI.faint()}#{state}#{IO.ANSI.reset()}")
    end)

    IO.puts("")
    IO.puts(IO.ANSI.faint() <> "Listen: candump -tz #{List.first(interfaces)}" <> IO.ANSI.reset())
    IO.puts(IO.ANSI.faint() <> "Send:   cansend #{List.first(interfaces)} 123#00FFAA5501020304" <> IO.ANSI.reset())
  end

  defp iface_state_label(iface) do
    case System.cmd("ip", ["-br", "link", "show", iface], stderr_to_stdout: true) do
      {output, 0} ->
        output |> String.trim() |> String.replace(~r/\s+/, " ")

      _ ->
        "?"
    end
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
    # vcan devices always report `state UNKNOWN` (no carrier), so trust the
    # IFF_UP flag in the flags column (`<NOARP,UP,LOWER_UP>`) instead.
    case System.cmd("ip", ["link", "show", iface], stderr_to_stdout: true) do
      {output, 0} -> String.contains?(output, ",UP,") or String.contains?(output, "<UP,")
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

    if sudo_cached?() do
      OvcsCli.Shell.exec!("sudo -n bash -c #{shell_quote(script)}")
    else
      password = prompt_password!()
      sudo_with_password!(password, "bash -c #{shell_quote(script)}")
    end
  end

  defp sudo_cached? do
    case System.cmd("sudo", ["-n", "true"], stderr_to_stdout: true) do
      {_, 0} -> true
      _ -> false
    end
  end

  # Disable echo on the user's tty using stty via a port with :nouse_stdio,
  # which leaves the child's fd 0 pointing at BEAM's inherited tty. Read
  # the password with IO.gets (which reads the same tty via the group
  # leader), then restore echo.
  defp prompt_password! do
    IO.write("[sudo] password: ")
    run_stty!("-echo")

    result =
      try do
        IO.gets("")
      after
        run_stty!("echo")
        IO.puts("")
      end

    case result do
      :eof ->
        IO.puts(IO.ANSI.yellow() <> "Aborted." <> IO.ANSI.reset())
        System.halt(130)

      {:error, _} ->
        IO.puts(IO.ANSI.red() <> "Could not read password." <> IO.ANSI.reset())
        System.halt(1)

      line ->
        String.trim_trailing(line)
    end
  end

  defp run_stty!(flag) do
    port = Port.open({:spawn, "stty #{flag}"}, [:nouse_stdio, :exit_status])
    receive do
      {^port, {:exit_status, _}} -> :ok
    after
      1_000 -> :ok
    end
  end

  defp sudo_with_password!(password, suffix) do
    cmd = "sudo -S -p '' " <> suffix
    IO.puts(IO.ANSI.cyan() <> "→ sudo …" <> IO.ANSI.reset())

    port =
      Port.open({:spawn, cmd}, [
        :binary,
        :exit_status,
        :use_stdio,
        :stderr_to_stdout
      ])

    Port.command(port, password <> "\n")
    stream_until_exit(port)
  end

  defp stream_until_exit(port) do
    receive do
      {^port, {:data, chunk}} ->
        IO.write(chunk)
        stream_until_exit(port)

      {^port, {:exit_status, 0}} ->
        :ok

      {^port, {:exit_status, code}} ->
        IO.puts(IO.ANSI.red() <> "✗ exited with #{code}" <> IO.ANSI.reset())
        System.halt(code)
    end
  end

  defp shell_quote(s), do: "'" <> String.replace(s, "'", "'\\''") <> "'"
end
