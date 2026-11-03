defmodule VisionCore.Firmware do
  @moduledoc """
  What the unit runs: the commit the firmware is built from and its Nerves
  target, which the firmware records under `:vision_core, :firmware` when it
  is built, and the Nerves system the board's `/usr/lib/os-release` names.
  A host has no Nerves system.
  """

  @enforce_keys [:revision, :target, :nerves_system, :nerves_system_version]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          revision: String.t() | nil,
          target: String.t() | nil,
          nerves_system: String.t() | nil,
          nerves_system_version: String.t() | nil
        }

  @doc "The firmware the unit runs, with the Nerves system `os_release` names."
  @spec current(Path.t()) :: t()
  def current(os_release \\ "/usr/lib/os-release") do
    build = Application.get_env(:vision_core, :firmware, [])
    release = read_os_release(os_release)

    %__MODULE__{
      revision: build[:revision],
      target: build[:target],
      nerves_system: release["NERVES_SYSTEM_NAME"],
      nerves_system_version: release["NERVES_SYSTEM_VERSION"]
    }
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
