defmodule VisionCore.TarTest do
  use ExUnit.Case, async: true

  alias VisionCore.Tar

  @moduletag :tmp_dir

  defp entry!(name, path) do
    {:ok, entry} = Tar.read_entry(name, path)
    entry
  end

  defp archive(entries), do: entries |> Tar.stream() |> Enum.into(<<>>)

  test "archives folders and files as tar reads them back, its size known before", %{
    tmp_dir: dir
  } do
    folder = Path.join(dir, "bag")
    File.mkdir_p!(folder)
    File.write!(Path.join(folder, "metadata.yaml"), "rosbag2_bagfile_information: ~")
    mcap = :crypto.strong_rand_bytes(5_000)
    File.write!(Path.join(folder, "bag_0.mcap"), mcap)

    entries = [
      entry!("bag/", folder),
      entry!("bag/metadata.yaml", Path.join(folder, "metadata.yaml")),
      entry!("bag/bag_0.mcap", Path.join(folder, "bag_0.mcap"))
    ]

    tar = archive(entries)

    assert byte_size(tar) == Tar.size(entries)
    assert rem(byte_size(tar), 512) == 0

    assert {:ok, files} = :erl_tar.extract({:binary, tar}, [:memory])

    assert Enum.sort(files) == [
             {~c"bag/bag_0.mcap", mcap},
             {~c"bag/metadata.yaml", "rosbag2_bagfile_information: ~"}
           ]

    assert {:ok, table} = :erl_tar.table({:binary, tar}, [:verbose])

    assert [
             {~c"bag", :directory, 0, _mtime, 0o755, 0, 0},
             {_, :regular, 30, _, 0o644, 0, 0},
             _mcap
           ] =
             table
  end

  test "puts a name longer than 100 bytes in the ustar prefix", %{tmp_dir: dir} do
    path = Path.join(dir, "file")
    File.write!(path, "content")
    name = String.duplicate("folder", 15) <> "/" <> String.duplicate("f", 90)

    assert {:ok, [{extracted, "content"}]} =
             :erl_tar.extract({:binary, archive([entry!(name, path)])}, [:memory])

    assert List.to_string(extracted) == name
  end

  test "writes the size it read from a file that grew since", %{tmp_dir: dir} do
    path = Path.join(dir, "growing")
    File.write!(path, "first")
    entry = entry!("growing", path)
    File.write!(path, " and more", [:append])

    assert {:ok, [{~c"growing", "first"}]} =
             :erl_tar.extract({:binary, archive([entry])}, [:memory])
  end

  test "streams a file in chunks, never whole", %{tmp_dir: dir} do
    path = Path.join(dir, "large")
    File.write!(path, :binary.copy(<<1>>, 3_000_000))

    chunks = [entry!("large", path)] |> Tar.stream() |> Enum.to_list()

    assert Enum.all?(chunks, &(IO.iodata_length(&1) <= 1_048_576))
  end

  test "answers why a file cannot be read" do
    assert {:error, :enoent} = Tar.read_entry("gone", "/nonexistent/gone")
  end
end
