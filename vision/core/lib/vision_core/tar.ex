defmodule VisionCore.Tar do
  @moduledoc """
  A tar archive, POSIX ustar, of folders and files, as a stream of
  blocks read from the files as it is consumed, so an archive of
  gigabytes never sits in memory. `VisionCore.Recordings` sends a
  recording's folders as one.

  Each entry's size and time are read once, by `read_entry/2`: `size/1`
  gives the archive's length before it is sent, and `stream/1` writes
  that many bytes of each file, the first ones of a file that grew
  since. A file that shrank raises `File.Error` while the stream runs.

  A name up to 100 bytes goes in the header's name, a longer one is
  split at a `/` into its 155-byte prefix and its name. Sizes up to
  8 GiB are written in octal, larger ones in base-256, as GNU tar and
  `:erl_tar` read them.

  Source: POSIX.1-2017, `pax`, "ustar Interchange Format".
  """

  @block_bytes 512
  @chunk_bytes 1_048_576
  @name_bytes 100
  @prefix_bytes 155
  @octal_size_limit 8_589_934_592

  @enforce_keys [:name, :type, :path, :size, :mtime]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          name: String.t(),
          type: :directory | :regular,
          path: Path.t(),
          size: non_neg_integer(),
          mtime: non_neg_integer()
        }

  @doc """
  The entry named `name` in the archive, of the folder or file at
  `path`: its type, size and time as they are now. A folder's name ends
  with `/`.
  """
  @spec read_entry(String.t(), Path.t()) :: {:ok, t()} | {:error, File.posix()}
  def read_entry(name, path) do
    case File.stat(path, time: :posix) do
      {:ok, %File.Stat{type: :directory, mtime: mtime}} ->
        {:ok, %__MODULE__{name: name, type: :directory, path: path, size: 0, mtime: mtime}}

      {:ok, %File.Stat{type: :regular, size: size, mtime: mtime}} ->
        {:ok, %__MODULE__{name: name, type: :regular, path: path, size: size, mtime: mtime}}

      {:ok, %File.Stat{}} ->
        {:error, :einval}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "The bytes of the archive of `entries`, as `stream/1` writes it."
  @spec size([t()]) :: non_neg_integer()
  def size(entries),
    do: Enum.sum_by(entries, &(@block_bytes + padded(&1.size))) + 2 * @block_bytes

  @doc """
  The archive of `entries`, in their order, as chunks of at most 1 MiB:
  each entry's header, its file's bytes and their padding, then the two
  empty blocks that end an archive.
  """
  @spec stream([t()]) :: Enumerable.t()
  def stream(entries) do
    entries
    |> Stream.flat_map(fn entry -> Stream.concat([[header(entry)], contents(entry)]) end)
    |> Stream.concat([<<0::size(2 * @block_bytes * 8)>>])
  end

  defp contents(%__MODULE__{type: :directory}), do: []

  defp contents(%__MODULE__{path: path, size: size}) do
    Stream.resource(
      fn -> {open!(path), size} end,
      fn
        {file, 0} ->
          {:halt, {file, 0}}

        {file, left} ->
          bytes = read!(file, path, min(left, @chunk_bytes))
          left = left - byte_size(bytes)
          {[bytes | if(left == 0, do: [padding(size)], else: [])], {file, left}}
      end,
      fn {file, _left} -> File.close(file) end
    )
  end

  defp open!(path) do
    case :file.open(path, [:read, :raw, :binary]) do
      {:ok, file} -> file
      {:error, reason} -> raise File.Error, reason: reason, action: "open", path: path
    end
  end

  defp read!(file, path, bytes) do
    case :file.read(file, bytes) do
      {:ok, read} -> read
      :eof -> raise File.Error, reason: :eof, action: "read", path: path
      {:error, reason} -> raise File.Error, reason: reason, action: "read", path: path
    end
  end

  defp padded(size), do: size + padding_bytes(size)

  defp padding(size), do: <<0::size(padding_bytes(size) * 8)>>

  defp padding_bytes(size), do: rem(@block_bytes - rem(size, @block_bytes), @block_bytes)

  defp header(entry) do
    {prefix, name} = split_name(entry.name)

    {mode, typeflag} =
      case entry.type do
        :directory -> {0o755, "5"}
        :regular -> {0o644, "0"}
      end

    fields = fn checksum ->
      [
        field(name, @name_bytes),
        octal(mode, 8),
        octal(0, 8),
        octal(0, 8),
        size_field(entry.size),
        octal(entry.mtime, 12),
        checksum,
        typeflag,
        field("", 100),
        "ustar\0",
        "00",
        field("", 32),
        field("", 32),
        octal(0, 8),
        octal(0, 8),
        field(prefix, @prefix_bytes),
        field("", 12)
      ]
    end

    unsummed = IO.iodata_to_binary(fields.("        "))
    checksum = for <<byte <- unsummed>>, reduce: 0, do: (sum -> sum + byte)
    checksum_field = String.pad_leading(Integer.to_string(checksum, 8), 6, "0") <> "\0 "
    IO.iodata_to_binary(fields.(checksum_field))
  end

  defp split_name(name) when byte_size(name) <= @name_bytes, do: {"", name}

  defp split_name(name) do
    parts = String.split(name, "/")

    split =
      Enum.find_value(1..(length(parts) - 1)//1, fn at ->
        {prefix, rest} = Enum.split(parts, at)
        {prefix, rest} = {Enum.join(prefix, "/"), Enum.join(rest, "/")}

        if byte_size(prefix) <= @prefix_bytes and byte_size(rest) <= @name_bytes and rest != "",
          do: {prefix, rest}
      end)

    split || raise ArgumentError, "#{name} is too long for a ustar header"
  end

  defp field(text, bytes), do: text <> <<0::size((bytes - byte_size(text)) * 8)>>

  # Digits, then a NUL, filling the field.
  defp octal(number, bytes),
    do: String.pad_leading(Integer.to_string(number, 8), bytes - 1, "0") <> "\0"

  defp size_field(size) when size < @octal_size_limit, do: octal(size, 12)
  defp size_field(size), do: <<0x80, size::big-unsigned-88>>
end
