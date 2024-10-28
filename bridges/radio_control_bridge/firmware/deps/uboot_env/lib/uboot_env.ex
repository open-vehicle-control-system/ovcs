defmodule UBootEnv do
  @moduledoc """
  UBootEnv reads and writes U-Boot environment blocks

  It's like the commandline tools `fw_setenv` and `fw_printenv` except in pure
  Elixir. It also uses `/etc/fw_env.config` by default to figure out where the
  environment exists so that you need not store the configuration in two
  places.
  """

  @default_config_file "/etc/fw_env.config"

  @doc """
  Read the U-Boot environment into a map or key value pairs

  The configuration from `"/etc/fw_env.config"` is used to find the location of
  the environment block. See `read/1` for specifying a custom location.
  """
  @spec read() :: {:ok, map()} | {:error, reason :: atom()}
  def read() do
    with {:ok, config} <- configuration() do
      read(config)
    end
  end

  @doc """
  Read the U-Boot environment into a map or key value pairs
  """
  @spec read(UBootEnv.Config.t()) :: {:ok, map()} | {:error, atom()}
  def read(config = %UBootEnv.Config{}) do
    with {:ok, contents} <- UBootEnv.IO.read(config) do
      {:ok, UBootEnv.Serializer.decode(contents)}
    end
  end

  @doc """
  Write a map of key value pairs to the U-Boot environment

  The configuration from `"/etc/fw_env.config"` is used to find the location of
  the environment block. See `write/2` for specifying a custom location.
  """
  @spec write(map()) :: :ok | {:error, reason :: atom()}
  def write(kv) when is_map(kv) do
    with {:ok, config} <- configuration() do
      write(kv, config)
    end
  end

  @doc """
  Write a map of key-value pairs to the U-Boot environment
  """
  @spec write(map, UBootEnv.Config.t()) :: :ok | {:error, atom()}
  def write(kv, %UBootEnv.Config{} = config) when is_map(kv) do
    encoded = UBootEnv.Serializer.encode(kv)
    UBootEnv.IO.write(config, encoded)
  end

  @doc """
  Load the U-Boot environment configuration

  This is returns the default U-Boot environment configuration from
  `"/etc/fw_env.config"`. If you do not want this, see
  `UBootEnv.Config.from_file/1` or `UBootEnv.Config.from_string/1` for
  creating or loading a custom configuration.
  """
  @spec configuration() :: {:ok, UBootEnv.Config.t()} | {:error, atom()}
  def configuration() do
    UBootEnv.Config.from_file(@default_config_file)
  end
end
