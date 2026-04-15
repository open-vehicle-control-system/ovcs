defmodule OvcsCli.Commands.Doctor do
  @moduledoc "Verify the host has everything the OVCS toolchain expects."

  alias OvcsCli.Vehicles

  @binaries [
    {"mise", "mise --version", "language-runtime manager", :required},
    {"elixir", "elixir --version", "Elixir runtime (mise-managed)", :required},
    {"mix", "mix --version", "Elixir build tool", :required},
    {"node", "node --version", "VMS dashboard build", :required},
    {"ruby", "ruby --version", "historical scripts", :optional},
    {"python", "python --version", "PlatformIO + tooling", :required},
    {"flutter", "flutter --version", "infotainment dashboard", :optional},
    {"fwup", "fwup --version", "Nerves firmware packaging", :required},
    {"cansend", "cansend", "can-utils", :optional},
    {"candump", "candump --version", "can-utils", :optional},
    {"pio", "pio --version", "Arduino controller builds", :optional}
  ]

  def run(repo_root) do
    ok = print_section("Toolchain binaries", fn -> check_binaries() end)
    ok = print_section("Nerves bootstrap", fn -> check_nerves_bootstrap() end) and ok
    ok = print_section("libsocketcan", fn -> check_libsocketcan() end) and ok
    ok = print_section("Vehicle packages", fn -> check_vehicles(repo_root) end) and ok

    IO.puts("")

    if ok do
      IO.puts(IO.ANSI.green() <> "All checks passed." <> IO.ANSI.reset())
    else
      IO.puts(IO.ANSI.yellow() <> "Some checks failed — see above." <> IO.ANSI.reset())
      IO.puts("  Required failures block builds; optional ones only matter for the relevant side.")
    end
  end

  defp print_section(title, fun) do
    IO.puts("")
    IO.puts(IO.ANSI.bright() <> title <> IO.ANSI.reset())
    fun.()
  end

  defp check_binaries do
    Enum.reduce(@binaries, true, fn {name, cmd, purpose, level}, acc ->
      result = check_binary(name, cmd, purpose, level)
      acc and result
    end)
  end

  defp check_binary(name, cmd, purpose, level) do
    [exe | args] = String.split(cmd, " ")

    if System.find_executable(exe) do
      try do
        System.cmd(exe, args, stderr_to_stdout: true)
        report(:ok, name, purpose)
        true
      rescue
        _ ->
          report(level_to_mark(level), name, "#{purpose} — on PATH but failed to run")
          level != :required
      end
    else
      report(level_to_mark(level), name, "#{purpose} — not on PATH")
      level != :required
    end
  end

  defp check_nerves_bootstrap do
    case System.cmd("mix", ["archive"], stderr_to_stdout: true) do
      {output, 0} ->
        if output =~ "nerves_bootstrap" do
          report(:ok, "nerves_bootstrap", "installed as Mix archive")
          true
        else
          report(:error, "nerves_bootstrap", "not installed; run `mise run bootstrap`")
          false
        end

      _ ->
        report(:error, "nerves_bootstrap", "could not run `mix archive`")
        false
    end
  end

  defp check_libsocketcan do
    candidates = [
      "/usr/include/libsocketcan.h",
      "/usr/local/include/libsocketcan.h"
    ]

    if Enum.any?(candidates, &File.exists?/1) do
      report(:ok, "libsocketcan", "header present")
      true
    else
      report(:warn, "libsocketcan", "header not found — needed for Cantastic on physical CAN")
      true
    end
  end

  defp check_vehicles(repo_root) do
    vehicles = Vehicles.list(repo_root)

    if vehicles == [] do
      report(:warn, "vehicles/", "no vehicle packages found")
      true
    else
      Enum.reduce(vehicles, true, fn v, acc ->
        vms = Vehicles.nerves_target(v, :vms)
        info = Vehicles.nerves_target(v, :infotainment)

        result =
          cond do
            vms == nil and info == nil ->
              report(:error, v.dir, "#{v.module}.nerves_target/1 returned nothing for either side")
              false

            true ->
              parts =
                [
                  vms && "vms → #{vms}",
                  info && "infotainment → #{info}"
                ]
                |> Enum.reject(&is_nil/1)
                |> Enum.join(", ")

              report(:ok, v.dir, parts)
              true
          end

        acc and result
      end)
    end
  end

  defp level_to_mark(:required), do: :error
  defp level_to_mark(:optional), do: :warn

  defp report(status, name, detail) do
    {mark, color} =
      case status do
        :ok -> {"✓", IO.ANSI.green()}
        :warn -> {"⚠", IO.ANSI.yellow()}
        :error -> {"✗", IO.ANSI.red()}
      end

    IO.puts("  #{color}#{mark}#{IO.ANSI.reset()} #{String.pad_trailing(name, 22)} #{IO.ANSI.faint()}#{detail}#{IO.ANSI.reset()}")
  end
end
