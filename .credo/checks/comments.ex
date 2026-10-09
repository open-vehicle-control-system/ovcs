defmodule Ovcs.Credo.Comments do
  @moduledoc """
  Splits a source file into comment blocks and code lines for the
  comment checks. Strings, heredocs and sigils are blanked first, so a
  `#` inside them is not a comment.
  """

  @doc """
  Returns `{blocks, code_lines}`. Each block is
  `{first_line_no, comment_lines, following_code_lines}`, where the
  following lines start at the first non-blank line after the block.
  """
  def parse(source_file) do
    lines =
      source_file
      |> Credo.Code.clean_charlists_strings_and_sigils()
      |> String.split("\n")
      |> Enum.with_index(1)

    comment? = fn {line, _} -> String.match?(line, ~r/^\s*#/) end
    code? = fn {line, _} -> String.trim(line) != "" and not comment?.({line, 0}) end

    blocks =
      lines
      |> Enum.chunk_by(comment?)
      |> Enum.chunk_every(2, 1, [[]])
      |> Enum.filter(fn [chunk | _] -> comment?.(hd(chunk)) end)
      |> Enum.map(fn [block, after_block] ->
        {_, first} = hd(block)
        following = after_block |> Enum.drop_while(&(not code?.(&1))) |> Enum.map(&elem(&1, 0))
        {first, Enum.map(block, &elem(&1, 0)), following}
      end)

    {blocks, Enum.map(Enum.filter(lines, code?), &elem(&1, 0))}
  end
end
