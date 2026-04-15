defmodule OvcsCli.Vehicles do
  @moduledoc """
  Discovers vehicle packages under `<repo>/vehicles/*` and queries their
  `OvcsVehicle` metadata without compiling them into the CLI's BEAM.
  """

  defstruct [:dir, :module, :path]

  @type t :: %__MODULE__{dir: String.t(), module: String.t(), path: String.t()}

  @spec list(String.t()) :: [t()]
  def list(repo_root) do
    repo_root
    |> Path.join("vehicles/*/mix.exs")
    |> Path.wildcard()
    |> Enum.map(fn mix_path ->
      dir = mix_path |> Path.dirname() |> Path.basename()
      %__MODULE__{dir: dir, module: module_for(dir), path: Path.dirname(mix_path)}
    end)
    |> Enum.sort_by(& &1.dir)
  end

  @doc "Derive the top-level Elixir module name from the snake_case dir name."
  def module_for(dir), do: dir |> String.split("_") |> Enum.map(&String.capitalize/1) |> Enum.join()

  @doc """
  Query a vehicle's `nerves_target/1` via a `mix run --no-start` spawn. Returns
  the target atom as a string, or `nil` if the vehicle has no target for that
  side.

  We shell out instead of loading the beam in-process so this keeps working
  even when the vehicle's deps aren't compiled into the CLI's build.
  """
  @spec nerves_target(t(), :vms | :infotainment) :: String.t() | nil
  def nerves_target(%__MODULE__{module: module, path: path}, side) do
    snippet =
      ~s|case function_exported?(#{module}, :nerves_target, 1) and #{module}.nerves_target(:#{side}) do | <>
        ~s|false -> :ok; target -> IO.write(to_string(target)) end|

    run_snippet(path, snippet)
  end

  @doc """
  Return the list of host CAN interface names the vehicle needs (by
  parsing each side's `default_can_mapping(:host)`). E.g. for Ovcs1
  this yields `["vcan0", "vcan1", "vcan2", "vcan3", "vcan4"]` for VMS
  plus the infotainment side.
  """
  @spec host_can_interfaces(t()) :: [String.t()]
  def host_can_interfaces(%__MODULE__{module: module, path: path}) do
    snippet = """
    m = #{module}
    sides =
      [m.vms()] ++
        if function_exported?(m, :infotainment, 0), do: [m.infotainment()], else: []
    sides
    |> Enum.map(& &1.default_can_mapping(:host))
    |> Enum.join(",")
    |> String.split(",", trim: true)
    |> Enum.map(fn kv -> kv |> String.split(":", trim: true) |> List.last() end)
    |> Enum.uniq()
    |> Enum.join("\\n")
    |> IO.puts()
    """

    case run_snippet(path, snippet) do
      nil -> []
      output -> String.split(output, "\n", trim: true)
    end
  end

  defp run_snippet(path, snippet) do
    # First attempt: no-deps-check / no-stderr-noise for the common
    # case where deps are already fetched and compiled.
    quiet = "mix run --no-start --no-deps-check -e #{escape(snippet)} 2>/dev/null"

    case System.cmd("sh", ["-c", quiet], cd: path, env: [{"MIX_ENV", "dev"}]) do
      {"", 0} -> nil
      {output, 0} -> String.trim(output)
      _ -> retry_with_deps(path, snippet)
    end
  end

  # Fallback: a freshly scaffolded vehicle has no deps yet, so the
  # first quiet invocation fails silently. Fetch + compile visibly,
  # then re-run the snippet quietly so the returned output is just
  # the snippet's IO.puts value — not compile noise.
  defp retry_with_deps(path, snippet) do
    IO.puts(
      IO.ANSI.faint() <>
        "Preparing vehicle #{Path.relative_to_cwd(path)} (first run)…" <>
        IO.ANSI.reset()
    )

    with :ok <- run_mix(path, ["deps.get"]),
         :ok <- run_mix(path, ["compile"]) do
      run_snippet_quiet(path, snippet)
    else
      {:error, output} ->
        IO.puts(IO.ANSI.red() <> output <> IO.ANSI.reset())
        nil
    end
  end

  defp run_mix(path, args) do
    case System.cmd("mix", args,
           cd: path,
           env: [{"MIX_ENV", "dev"}],
           stderr_to_stdout: true,
           into: IO.stream(:stdio, :line)
         ) do
      {_, 0} -> :ok
      {output, _} -> {:error, to_string(output)}
    end
  end

  defp run_snippet_quiet(path, snippet) do
    cmd = "mix run --no-start --no-deps-check -e #{escape(snippet)} 2>/dev/null"

    case System.cmd("sh", ["-c", cmd], cd: path, env: [{"MIX_ENV", "dev"}]) do
      {"", 0} -> nil
      {output, 0} -> String.trim(output)
      _ -> nil
    end
  end

  defp escape(snippet) do
    "'" <> String.replace(snippet, "'", "'\\''") <> "'"
  end
end
