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

    case System.cmd("sh", ["-c", "mix run --no-start --no-deps-check -e #{escape(snippet)} 2>/dev/null"],
           cd: path,
           env: [{"MIX_ENV", "dev"}]
         ) do
      {"", 0} -> nil
      {output, 0} -> String.trim(output)
      _ -> nil
    end
  end

  defp escape(snippet) do
    "'" <> String.replace(snippet, "'", "'\\''") <> "'"
  end
end
