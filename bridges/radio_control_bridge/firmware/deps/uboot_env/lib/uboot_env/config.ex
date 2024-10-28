defmodule UBootEnv.Config do
  @moduledoc """
  Utilities for reading the U-Boot's `fw_env.config` file.
  """

  alias UBootEnv.Location

  defstruct [:locations]
  @type t() :: %__MODULE__{locations: [Location.t()]}

  @doc """
  Create a UBootEnv.Config from a file (`/etc/fw_env.config` by default)

  This file should be formatted as described in `from_string/1`.
  """
  @spec from_file(Path.t()) :: {:ok, t()} | {:error, atom()}
  def from_file(config_file) do
    with {:ok, config} <- File.read(config_file) do
      from_string(config)
    end
  end

  @doc """
  Raising version of `from_file/1`
  """
  @spec from_file!(Path.t()) :: UBootEnv.Config.t()
  def from_file!(config) do
    case from_file(config) do
      {:ok, result} -> result
      {:error, reason} -> raise reason
    end
  end

  @doc """
  Create a UBootEnv.Config from the contents of an `fw_env.config` file

  Only one or two U-Boot environment locations are supported. Each location
  row has the following format:

  ```
  <Device name>	<Device offset>	<Env. size>	[Flash sector size]	[Number of sectors]
  ```
  """
  @spec from_string(String.t()) :: {:ok, t()} | {:error, atom()}
  def from_string(config) do
    config
    |> parse_file()
    |> Enum.flat_map(&parse_line/1)
    |> locations_to_config()
  end

  @doc """
  Raising version of `from_string/1`
  """
  @spec from_string!(String.t()) :: UBootEnv.Config.t()
  def from_string!(config) do
    case from_string(config) do
      {:ok, result} -> result
      {:error, reason} -> raise reason
    end
  end

  @doc """
  Return the environment block size
  """
  @spec size(t()) :: pos_integer()
  def size(config) do
    first(config).size
  end

  @doc """
  Return the first location
  """
  @spec first(t()) :: Location.t()
  def first(config) do
    hd(config.locations)
  end

  @doc """
  Return the second location

  This raises for nonredundant environments.
  """
  @spec second(t()) :: Location.t()
  def second(config) do
    [_first, second] = config.locations
    second
  end

  @doc """
  Return whether this is a redundant environment
  """
  @spec format(t()) :: :redundant | :nonredundant
  def format(config) do
    case length(config.locations) do
      1 -> :nonredundant
      2 -> :redundant
    end
  end

  defp parse_file(config) do
    for line <- String.split(config, "\n", trim: true),
        line != "",
        !String.starts_with?(line, "#"),
        do: line
  end

  defp parse_line(line) do
    case line |> String.split() |> Enum.map(&String.trim/1) do
      [dev_name, dev_offset, env_size | _] ->
        [
          %UBootEnv.Location{
            path: dev_name,
            offset: parse_int(dev_offset),
            size: parse_int(env_size)
          }
        ]

      _other ->
        []
    end
  end

  defp locations_to_config(locations) do
    case length(locations) do
      count when count == 1 or count == 2 ->
        {:ok, %__MODULE__{locations: locations}}

      _other ->
        {:error, :parse_error}
    end
  end

  @doc """
  Parse an integer

  Examples:

  ```elixir
  iex> UBootEnv.Config.parse_int("0x12")
  18

  iex> UBootEnv.Config.parse_int("1234")
  1234
  ```
  """
  @spec parse_int(String.t()) :: integer()
  def parse_int(<<"0x", hex_int::binary>>), do: String.to_integer(hex_int, 16)
  def parse_int(decimal_int), do: String.to_integer(decimal_int)
end
