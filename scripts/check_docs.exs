#!/usr/bin/env elixir
#
# Checks the guides published on ovcs.be against the documentation rules
# in CODE_STYLING.md. The published set is every Markdown file linked from the
# index, docs/README.md; its sections and order are the site's docs tree.
#
# Usage: elixir scripts/check_docs.exs

index = "docs/README.md"

# Ask git rather than the filesystem: the sideloaded libraries/ clones
# exist locally but not in a CI checkout.
{listing, 0} = System.cmd("git", ["ls-files", "--cached", "--others", "--exclude-standard"])
files = listing |> String.split("\n", trim: true) |> MapSet.new()

exists? = fn path ->
  path = String.trim_trailing(path, "/")
  path in files or Enum.any?(files, &String.starts_with?(&1, path <> "/"))
end

strip_code = fn text ->
  text
  |> String.replace(~r/^[ \t]*(```|~~~).*?^[ \t]*\1/ms, "")
  |> String.replace(~r/`[^`\n]*`/, "")
end

# GitHub's heading anchors: lowercase, punctuation dropped, spaces to dashes.
anchor = fn heading ->
  heading
  |> String.replace(~r/\[([^\]]*)\]\([^)]*\)/, "\\1")
  |> String.downcase()
  |> String.replace(~r/[^\p{L}\p{N}\s_-]/u, "")
  |> String.replace(" ", "-")
end

anchors_of = fn path ->
  path
  |> File.read!()
  |> String.replace(~r/^[ \t]*(```|~~~).*?^[ \t]*\1/ms, "")
  |> then(&Regex.scan(~r/^#+\s+(.+?)\s*$/m, &1, capture: :all_but_first))
  |> Enum.map(fn [h] -> anchor.(h) end)
  |> MapSet.new()
end

top_level_directories =
  files |> Enum.filter(&String.contains?(&1, "/")) |> Enum.map(&(&1 |> String.split("/") |> hd())) |> MapSet.new()

ignored? = fn path -> match?({_, 0}, System.cmd("git", ["check-ignore", "-q", path])) end

# The names the tutorials build under, which exist in no checkout.
example_names = ~w(my_car board_temperature_bridge)

# Repo paths named in inline code: a path whose first segment is a top-level
# directory. A numeric last segment is a function arity (`vms/0`).
code_paths_of = fn text ->
  text
  |> String.replace(~r/^[ \t]*(```|~~~).*?^[ \t]*\1/ms, "")
  |> then(&Regex.scan(~r/`([^`\n]+)`/, &1, capture: :all_but_first))
  |> List.flatten()
  |> Enum.filter(&String.match?(&1, ~r{^[\w.-]+(/[\w.-]+)+/?$}))
  |> Enum.reject(&String.match?(&1, ~r{/\d+$}))
  |> Enum.filter(&((&1 |> String.split("/") |> hd()) in top_level_directories))
  |> Enum.reject(fn path -> Enum.any?(example_names, &(&1 in String.split(path, "/"))) end)
  |> Enum.uniq()
end

links_of = fn text ->
  Regex.scan(~r/\]\(([^)\s]+)\)/, strip_code.(text), capture: :all_but_first) |> List.flatten()
end

index_text = File.read!(index)

published =
  index_text
  |> links_of.()
  |> Enum.reject(&String.match?(&1, ~r/^[a-z]+:|^#/))
  |> Enum.map(&(Path.join("docs", &1) |> Path.expand() |> Path.relative_to_cwd()))
  |> Enum.uniq()

unindexed =
  files
  |> Enum.filter(&(String.starts_with?(&1, "docs/") and String.ends_with?(&1, ".md") and File.regular?(&1)))
  |> Enum.reject(&(&1 == index or &1 in published))
  |> Enum.sort()
  |> Enum.map(&"#{&1}: not linked from #{index}")

# The site's tree: each ## section holds either entries or ### sub-sections.
index_items =
  index_text
  |> String.split("\n")
  |> Enum.with_index(1)
  |> Enum.map_reduce(false, fn {line, n}, fenced ->
    cond do
      String.match?(line, ~r/^[ \t]*(```|~~~)/) -> {nil, not fenced}
      fenced -> {nil, fenced}
      title = Regex.run(~r/^## (.+?)\s*$/, line, capture: :all_but_first) -> {{:section, n, hd(title)}, fenced}
      String.match?(line, ~r/^### /) -> {{:group, n}, fenced}
      String.match?(line, ~r/^- \[/) -> {{:entry, n}, fenced}
      true -> {nil, fenced}
    end
  end)
  |> elem(0)
  |> Enum.reject(&is_nil/1)

{orphans, sectioned} = Enum.split_while(index_items, &(elem(&1, 0) != :section))

index_shape =
  Enum.map(orphans, &"#{index}:#{elem(&1, 1)}: entry or sub-section before the first section") ++
    (sectioned
     |> Enum.chunk_while(
       [],
       fn
         {:section, _, _} = section, [] -> {:cont, [section]}
         {:section, _, _} = section, acc -> {:cont, Enum.reverse(acc), [section]}
         item, acc -> {:cont, [item | acc]}
       end,
       fn
         [] -> {:cont, []}
         acc -> {:cont, Enum.reverse(acc), []}
       end
     )
     |> Enum.flat_map(fn [{:section, _, title} | items] ->
       {direct, rest} = Enum.split_while(items, &(elem(&1, 0) == :entry))
       if direct != [] and rest != [], do: ["#{index}: section #{title} mixes entries and sub-sections"], else: []
     end))

check_file = fn path ->
  if exists?.(path) do
    raw = File.read!(path)

    {front, body} =
      case Regex.run(~r/\A---\n(.*?)\n---\n(.*)\z/s, raw, capture: :all_but_first) do
        [front, body] -> {front, body}
        nil -> {nil, raw}
      end

    prose = strip_code.(body)

    fences =
      Regex.scan(~r/^(\s*)(```|~~~)(.*)$/m, body, capture: :all_but_first)
      |> Enum.with_index()
      |> Enum.filter(fn {[_indent, _fence, lang], i} -> rem(i, 2) == 0 and String.trim(lang) == "" end)

    links =
      body
      |> links_of.()
      |> Enum.reject(&String.match?(&1, ~r/^[a-z]+:/))
      |> Enum.flat_map(fn link ->
        [file, frag] =
          case String.split(link, "#", parts: 2) do
            [file, frag] -> [file, frag]
            [file] -> [file, nil]
          end

        target = if file == "", do: path, else: Path.join(Path.dirname(path), file) |> Path.expand() |> Path.relative_to_cwd()

        cond do
          not exists?.(target) -> ["broken link #{link}"]
          frag && String.ends_with?(target, ".md") && frag not in anchors_of.(target) -> ["broken anchor #{link}"]
          true -> []
        end
      end)

    missing_paths =
      body
      |> code_paths_of.()
      |> Enum.reject(&(exists?.(&1) or ignored?.(&1)))
      |> Enum.map(&"`#{&1}` does not exist")

    [
      front == nil && "no frontmatter",
      front && not String.match?(front, ~r/^title: \S/m) && "frontmatter has no title",
      front && not String.match?(front, ~r/^description: \S/m) && "frontmatter has no description",
      front && String.match?(front, ~r/^(title|description): [^"'].*: /m) &&
        "frontmatter value holds `: ` unquoted (invalid YAML)",
      String.match?(prose, ~r/^# /m) && "H1 heading (the title comes from the frontmatter)",
      String.contains?(body, "```mermaid") && "Mermaid block",
      String.match?(prose, ~r/<(?!https?:)[A-Za-z!\/][^>\n]*>/) &&
        "raw HTML: #{Regex.run(~r/<(?!https?:)[A-Za-z!\/][^>\n]*>/, prose) |> hd()}",
      String.match?(body, ~r/<app>|<App>/) && "`<app>` placeholder (use `<vehicle>`)",
      fences != [] && "#{length(fences)} code fence(s) without a language"
    ]
    |> Enum.filter(& &1)
    |> Kernel.++(links)
    |> Kernel.++(missing_paths)
    |> Enum.map(&"#{path}: #{&1}")
  else
    ["#{path}: linked from #{index} but missing"]
  end
end

problems = index_shape ++ unindexed ++ Enum.flat_map(published, check_file)

if problems == [] do
  IO.puts("#{length(published)} published guides pass")
else
  Enum.each(problems, &IO.puts(:stderr, &1))
  IO.puts(:stderr, "\n#{length(problems)} problem(s)")
  System.halt(1)
end
