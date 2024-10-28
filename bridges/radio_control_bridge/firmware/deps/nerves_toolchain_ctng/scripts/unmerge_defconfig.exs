#!/usr/bin/env elixir

defmodule Unmerger do
  def load(filename) do
    File.stream!(filename)
    |> Enum.to_list
    |> Enum.map(&String.trim/1)
  end

  def remove_fragments(result, frag) do
    result
    |> Enum.filter(fn line -> line not in frag end)
  end

  # Check if the configs are similar enough. Some discrepancies
  # are allowed due to host platform differences or clarity of
  # the configs.
  def is_similar_enough(orig, got) do
    List.myers_difference(orig, got)
    |> Enum.flat_map(&expand_myers_difference/1)
    |> Enum.all?(&delta_ok/1)
  end

  defp expand_myers_difference({op, list}) do
    for item <- list do
      {op, item}
    end
  end

  defp delta_ok({:eq, _}), do: true
  defp delta_ok({:del, "CT_LIBC_GLIBC=y"}), do: true
  defp delta_ok({:del, "CT_CONFIG_VERSION=\"3\""}), do: true
  defp delta_ok(delta) do
    IO.puts("ERROR: defconfig delta not ok -> #{inspect delta}")
    false
  end

  def save(filename, contents) do
    lines = Enum.map(contents, fn line -> line <> "\n" end)
    File.write!(filename, lines)
  end

  def main([original_defconfig, fragment_defconfig, resulting_defconfig]) do
    IO.puts("Unmerging #{resulting_defconfig} into #{original_defconfig} using #{fragment_defconfig}\n")
    orig = load(original_defconfig)
    frag = load(fragment_defconfig)
    result = load(resulting_defconfig)

    desired = remove_fragments(result, frag)

    if !is_similar_enough(orig, desired) do
      IO.puts("\n\nDifferences detected between the original defconfig and the resulting one!!!")
      IO.puts("Please fix. I'm going to update the original for you to check.")

      save(original_defconfig, desired)
      1
    else
      0
    end
  end

  def main(_) do
    IO.puts("unmerge_defconfig.exs <original defconfig> <fragment defconfig> <resulting defconfig>")
    1
  end
end

Unmerger.main(System.argv())
|> :init.stop()
