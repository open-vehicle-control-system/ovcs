defmodule VisionCore.Disk do
  @moduledoc """
  One disk recordings go on, as `VisionCore.Disks` lists it: the unit's
  own storage, `internal`, or a USB disk's partition known by its
  filesystem's UUID.

  A USB disk is identified by its superblock, which `identify/1` reads,
  as the unit has no `blkid` and no `/dev/disk/by-uuid`:

    * f2fs (`struct f2fs_super_block`, Linux `include/linux/f2fs_fs.h`):
      at byte 1024, the magic `0xF2F52010`; the UUID 108 bytes in, the
      label, UTF-16LE, 124 bytes in.
    * ext4 (`struct ext4_super_block`, Linux `fs/ext4/ext4.h`): at byte
      1024, the magic `0xEF53` 56 bytes in, the UUID 104 bytes in, the
      label, 16 bytes, 120 bytes in. ext2 and ext3 share it, and the
      kernel's ext4 driver mounts them.

  Its `state`:

    * `:mounted` — recordings can go on it, in `recordings_path`.
    * `:ejecting` — being unmounted; nothing new goes on it.
    * `:ejected` — unmounted, still plugged in.
    * `:unplugged` — known, not plugged in.
    * `:unusable` — plugged in but not mounted, `problem` says why.
  """

  @superblock_bytes 4096
  @f2fs_magic 0xF2F52010
  @ext4_magic 0xEF53
  @f2fs_label_bytes 1024
  @ext4_label_bytes 16
  @no_uuid <<0::128>>

  @type filesystem :: :f2fs | :ext4
  @type state :: :mounted | :ejecting | :ejected | :unplugged | :unusable
  @type identity :: %{filesystem: filesystem(), uuid: String.t(), label: String.t()}

  @type t :: %__MODULE__{
          uuid: String.t() | nil,
          label: String.t() | nil,
          filesystem: filesystem() | nil,
          device: String.t() | nil,
          size_bytes: non_neg_integer() | nil,
          free_bytes: non_neg_integer() | nil,
          recordings_path: Path.t() | nil,
          position: non_neg_integer() | nil,
          enabled: boolean(),
          state: state(),
          problem: String.t() | nil,
          last_seen_at: DateTime.t() | nil
        }

  defstruct [
    :uuid,
    :label,
    :filesystem,
    :device,
    :size_bytes,
    :free_bytes,
    :recordings_path,
    :position,
    :problem,
    :last_seen_at,
    enabled: true,
    state: :unplugged
  ]

  @doc """
  The filesystem, UUID and label of the superblock in `bytes`, a
  partition's first bytes; an error for another filesystem, or one
  without a UUID.
  """
  @spec identify(binary()) :: {:ok, identity()} | {:error, String.t()}
  def identify(
        <<_boot::binary-1024, @f2fs_magic::little-32, _fields::binary-104, uuid::binary-16,
          label::binary-size(@f2fs_label_bytes), _rest::binary>>
      ),
      do: identity(:f2fs, uuid, utf16_label(label))

  def identify(
        <<_boot::binary-1080, @ext4_magic::little-16, _fields::binary-46, uuid::binary-16,
          label::binary-size(@ext4_label_bytes), _rest::binary>>
      ),
      do: identity(:ext4, uuid, byte_label(label))

  def identify(_bytes), do: {:error, "no f2fs or ext4 filesystem"}

  @doc "The identity of the filesystem on the device at `path`, as `identify/1` reads it."
  @spec read_identity(Path.t()) :: {:ok, identity()} | {:error, String.t()}
  def read_identity(path) do
    case :file.open(path, [:read, :raw, :binary]) do
      {:ok, device} ->
        read = :file.pread(device, 0, @superblock_bytes)
        :file.close(device)
        identify_read(read, path)

      {:error, reason} ->
        {:error, "cannot read #{path}: #{:file.format_error(reason)}"}
    end
  end

  defp identify_read({:ok, bytes}, _path), do: identify(bytes)
  defp identify_read(:eof, _path), do: identify(<<>>)

  defp identify_read({:error, reason}, path),
    do: {:error, "cannot read #{path}: #{:file.format_error(reason)}"}

  @doc "Whether `disk` is mounted with at least `free_floor_bytes` free."
  @spec writable?(t(), non_neg_integer()) :: boolean()
  def writable?(%__MODULE__{state: :mounted, free_bytes: free_bytes}, free_floor_bytes)
      when is_integer(free_bytes),
      do: free_bytes >= free_floor_bytes

  def writable?(%__MODULE__{}, _free_floor_bytes), do: false

  defp identity(_filesystem, @no_uuid, _label), do: {:error, "the filesystem has no UUID"}

  defp identity(filesystem, uuid, label),
    do: {:ok, %{filesystem: filesystem, uuid: format_uuid(uuid), label: label}}

  defp format_uuid(<<a::binary-4, b::binary-2, c::binary-2, d::binary-2, e::binary-6>>),
    do: Enum.map_join([a, b, c, d, e], "-", &Base.encode16(&1, case: :lower))

  defp utf16_label(bytes) do
    units = for <<unit::little-16 <- bytes>>, do: unit
    characters = Enum.take_while(units, &(&1 != 0))

    case :unicode.characters_to_binary(
           for(unit <- characters, into: <<>>, do: <<unit::little-16>>),
           {:utf16, :little}
         ) do
      label when is_binary(label) -> label
      _invalid -> ""
    end
  end

  defp byte_label(bytes) do
    [label | _padding] = :binary.split(bytes, <<0>>)
    if String.valid?(label), do: label, else: :unicode.characters_to_binary(label, :latin1)
  end
end
