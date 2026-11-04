defmodule OvcsVehicle.FirmwareInfo do
  @moduledoc """
  What a firmware runs, as each dashboard's top bar shows it: the commit it
  is built from and its Nerves target, which the firmware's `config.exs`
  records under `:ovcs_vehicle, :firmware`, the Nerves system the board's
  `/usr/lib/os-release` names, and the name of the vehicle `VEHICLE`
  selects. A host has no Nerves system.
  """

  @enforce_keys [:revision, :target, :nerves_system, :nerves_system_version, :vehicle]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          revision: String.t() | nil,
          target: String.t() | nil,
          nerves_system: String.t() | nil,
          nerves_system_version: String.t() | nil,
          vehicle: String.t() | nil
        }

  @doc "The firmware this node runs, with the Nerves system `os_release` names; no vehicle without `VEHICLE`."
  @spec current(Path.t()) :: t()
  def current(os_release \\ "/usr/lib/os-release") do
    build = Application.get_env(:ovcs_vehicle, :firmware, [])
    release = read_os_release(os_release)

    %__MODULE__{
      revision: build[:revision],
      target: build[:target],
      nerves_system: release["NERVES_SYSTEM_NAME"],
      nerves_system_version: release["NERVES_SYSTEM_VERSION"],
      vehicle: vehicle_name()
    }
  end

  defp vehicle_name do
    case Application.get_env(:ovcs_vehicle, :module) do
      nil -> nil
      vehicle -> vehicle.name()
    end
  end

  defp read_os_release(path) do
    case File.read(path) do
      {:ok, contents} -> parse_os_release(contents)
      {:error, _reason} -> %{}
    end
  end

  defp parse_os_release(contents) do
    for line <- String.split(contents, "\n"),
        [key, value] <- [String.split(line, "=", parts: 2)],
        into: %{},
        do: {key, value |> String.trim() |> unquote_value()}
  end

  # An os-release value may be quoted, as in a shell assignment.
  defp unquote_value(<<quote, rest::binary>>) when quote in [?", ?'],
    do: String.trim_trailing(rest, <<quote>>)

  defp unquote_value(value), do: value
end
