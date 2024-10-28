defmodule UBootEnv.IO do
  @moduledoc """
  Functions for reading and writing raw blocks to storage

  This is the module that handles the low level CRC32 and redundant block
  details.
  """
  alias UBootEnv.{Config, Location}

  @type generation() :: byte() | :unused

  @doc """
  Read a U-Boot environment block

  This function performs the actual read and in the case of redundant U-Boot
  environments, it returns the newer block. It does not decode.
  """
  @spec read(Config.t()) :: {:ok, binary()} | {:error, any()}
  def read(config = %Config{}) do
    # read all locations and pick the only or latest one.
    format = Config.format(config)

    config.locations
    |> Enum.map(&read_and_unpackage(&1, format))
    |> Enum.filter(fn result -> match?({:ok, _contents, _generation}, result) end)
    |> pick_best_for_reading()
  end

  defp read_and_unpackage(location, format) do
    with {:ok, bin} <- read_location(location) do
      unpackage(bin, format)
    end
  end

  defp pick_best_for_reading([]), do: {:error, :no_valid_blocks}
  defp pick_best_for_reading([{:ok, contents, _generation}]), do: {:ok, contents}

  defp pick_best_for_reading([{:ok, contents1, generation1}, {:ok, contents2, generation2}]) do
    if newer?(generation1, generation2) do
      {:ok, contents1}
    else
      {:ok, contents2}
    end
  end

  defp newer?(a, b) do
    # a and b are unsigned bytes (0-255) that count up. Roughly speaking,
    # a is newer than b if it is greater than b. When wrapping, we have to
    # deal with a=0 being newer than b=255. The solution is to use 8-bit
    # subtraction. In Elixir, subtract and mask to 8 bits. Then pick the
    # halfway point in the range of values to decide newer or older.
    :erlang.band(a - b, 0xFF) < 128
  end

  @doc """
  Write a U-Boot environment block

  This function performs the actual write. In the case of redundant
  U-Boot environments, it writes the block in the right location and
  marks the generation byte appropriately so that it is used on the next
  read. It does not encode.
  """
  @spec write(Config.t(), iodata()) :: :ok | {:error, atom()}
  def write(config = %Config{}, data) do
    do_write(Config.format(config), config, IO.iodata_to_binary(data))
  end

  defp do_write(:nonredundant, config, flattened_data) do
    with {:ok, packaged_data} <- package(flattened_data, Config.size(config), :unused) do
      write_location(Config.first(config), packaged_data)
    end
  end

  defp do_write(:redundant, config, flattened_data) do
    {location, gen} = find_write_location(config)

    with {:ok, packaged_data} <- package(flattened_data, Config.size(config), gen) do
      write_location(location, packaged_data)
    end
  end

  defp find_write_location(config) do
    result1 = read_and_unpackage(Config.first(config), :redundant)
    result2 = read_and_unpackage(Config.second(config), :redundant)

    case location_and_gen_to_write(result1, result2) do
      {1, gen} -> {Config.first(config), gen}
      {2, gen} -> {Config.second(config), gen}
    end
  end

  # Prefer writing over corrupt and old locations
  defp location_and_gen_to_write({:error, _}, {:error, _}), do: {1, 0}

  defp location_and_gen_to_write({:ok, _contents, generation}, {:error, _}),
    do: {2, incr_generation(generation)}

  defp location_and_gen_to_write({:error, _}, {:ok, _contents, generation}),
    do: {1, incr_generation(generation)}

  defp location_and_gen_to_write({:ok, _contents1, gen1}, {:ok, _contents2, gen2}) do
    if newer?(gen1, gen2) do
      {2, incr_generation(gen1)}
    else
      {1, incr_generation(gen2)}
    end
  end

  defp incr_generation(x), do: :erlang.band(x + 1, 0xFF)

  @doc """
  Package up U-Boot environment contents

  The result can be written to where ever the environment block is persisted.
  """
  @spec package(binary(), pos_integer(), generation()) ::
          {:ok, iodata()} | {:error, :environment_too_small}
  def package(bin, env_size, generation) do
    padding_len = env_size - byte_size(bin) - header_size(generation)

    if padding_len >= 0 do
      padding = :binary.copy(<<-1>>, padding_len)

      crc = :erlang.crc32([bin, padding])
      {:ok, [<<crc::little-size(32)>>, encode_generation(generation), bin, padding]}
    else
      {:error, :environment_too_small}
    end
  end

  defp header_size(:unused), do: 4
  defp header_size(_generation), do: 5

  defp encode_generation(:unused), do: []
  defp encode_generation(generation) when generation >= 0 and generation < 256, do: generation

  @doc """
  Unpackage a U-Boot environment block

  This is the opposite of package/3. It will only return successfully
  if the input passes the U-Boot CRC check.
  """
  @spec unpackage(binary(), :redundant | :nonredundant) ::
          {:ok, binary(), generation()} | {:error, :invalid_crc}
  def unpackage(<<expected_crc::little-32, contents::binary>>, :nonredundant) do
    with :ok <- validate_crc(contents, expected_crc) do
      {:ok, contents, :unused}
    end
  end

  def unpackage(<<expected_crc::little-32, generation, contents::binary>>, :redundant) do
    with :ok <- validate_crc(contents, expected_crc) do
      {:ok, contents, generation}
    end
  end

  defp validate_crc(contents, expected) do
    case :erlang.crc32(contents) do
      ^expected -> :ok
      _other -> {:error, :invalid_crc}
    end
  end

  defp read_location(location = %Location{}) do
    case File.open(location.path, [:raw, :binary, :read]) do
      {:ok, fd} ->
        rc = :file.pread(fd, location.offset, location.size) |> eof_is_error()
        _ = File.close(fd)
        rc

      error ->
        error
    end
  end

  defp write_location(location = %Location{}, contents) do
    case File.open(location.path, [:raw, :binary, :write, :read]) do
      {:ok, fd} ->
        rc = :file.pwrite(fd, location.offset, contents)
        _ = :file.sync(fd)
        _ = File.close(fd)
        rc

      error ->
        error
    end
  end

  defp eof_is_error(:eof), do: {:error, :empty}
  defp eof_is_error(other), do: other
end
