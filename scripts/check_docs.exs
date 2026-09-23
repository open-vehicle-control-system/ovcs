#!/usr/bin/env elixir
#
# Checks the guides published on ovcs.be against the documentation rules
# in CLAUDE.md. The published set is every Markdown file linked from the
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
  Path.wildcard("docs/*.md")
  |> Enum.reject(&(&1 == index or &1 in published))
  |> Enum.map(&"#{&1}: not linked from #{index}")

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

    [
      front == nil && "no frontmatter",
      front && not String.match?(front, ~r/^title: \S/m) && "frontmatter has no title",
      front && not String.match?(front, ~r/^description: \S/m) && "frontmatter has no description",
      String.match?(prose, ~r/^# /m) && "H1 heading (the title comes from the frontmatter)",
      String.contains?(body, "```mermaid") && "Mermaid block",
      String.match?(prose, ~r/<(?!https?:)[A-Za-z!\/][^>\n]*>/) &&
        "raw HTML: #{Regex.run(~r/<(?!https?:)[A-Za-z!\/][^>\n]*>/, prose) |> hd()}",
      String.match?(body, ~r/<vehicle>|<Vehicle>/) && "`<vehicle>` placeholder (use `<app>`)",
      String.match?(prose, ~r/\b(supported|shipped) vehicles\b/i) && "\"supported/shipped vehicles\" (reference applications)",
      fences != [] && "#{length(fences)} code fence(s) without a language"
    ]
    |> Enum.filter(& &1)
    |> Kernel.++(links)
    |> Enum.map(&"#{path}: #{&1}")
  else
    ["#{path}: linked from #{index} but missing"]
  end
end

problems = unindexed ++ Enum.flat_map(published, check_file)

if problems == [] do
  IO.puts("#{length(published)} published guides pass")
else
  Enum.each(problems, &IO.puts(:stderr, &1))
  IO.puts(:stderr, "\n#{length(problems)} problem(s)")
  System.halt(1)
end
