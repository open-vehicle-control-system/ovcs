defmodule Ovcs.Credo.Check.CommentBlocks do
  use Credo.Check,
    id: "OVCS001",
    base_priority: :normal,
    category: :readability,
    param_defaults: [max_lines: 3],
    explanations: [
      check: """
      Comments are for a non-obvious why, an invariant or a trap, and stay
      short (CODE_STYLING.md, "Names, docs and comments"):

      - a public function is documented with `@doc`, not a comment block;
      - a private function gets at most one line above it;
      - no comment runs longer than `max_lines`;
      - no history: git holds it.

      When code needs a longer comment, rename, extract a well-named
      function, or move the explanation into `@moduledoc`.
      """,
      params: [max_lines: "Longest comment block allowed."]
    ]

  alias Ovcs.Credo.Comments

  @history ~r/\b(previously|formerly|used to be|was changed|were changed|was replaced|were replaced|was removed|were removed)\b/i
  @public_def ~r/^\s*(?:def|defmacro|defguard)\s+([a-z_][a-zA-Z0-9_?!]*)/
  @private_def ~r/^\s*(defp|defmacrop|defguardp)\s/

  @doc false
  @impl true
  def run(%SourceFile{} = source_file, params) do
    issue_meta = IssueMeta.for(source_file, params)
    max_lines = Params.get(params, :max_lines, __MODULE__)
    {blocks, _code_lines} = Comments.parse(source_file)
    source = SourceFile.source(source_file)

    for {first, comment_lines, following} <- blocks,
        message = offence(first, comment_lines, following, source, max_lines),
        do: format_issue(issue_meta, message: message, line_no: first)
  end

  defp offence(first, comment_lines, following, source, max_lines) do
    size = length(comment_lines)
    target = Enum.find(following, "", &(not String.match?(&1, ~r/^\s*@(impl|spec)\b/)))

    cond do
      String.match?(Enum.join(comment_lines, " "), @history) ->
        "Comment tells history; git holds it."

      first_public_clause?(following, first, source) ->
        "Comment block above a public function; use @doc."

      size > 1 and String.match?(target, @private_def) ->
        "#{size}-line comment above a private function; rename or split it, or keep one line."

      size > max_lines ->
        "#{size}-line comment, at most #{max_lines}."

      true ->
        nil
    end
  end

  # A callback (@impl) or a later clause takes no @doc.
  defp first_public_clause?(following, first, source) do
    with [line | _] <- Enum.reject(following, &String.match?(&1, ~r/^\s*@spec\b/)),
         false <- String.match?(line, ~r/^\s*@impl\b/),
         [_, name] <- Regex.run(@public_def, line) do
      earlier = source |> String.split("\n") |> Enum.take(first - 1) |> Enum.join("\n")
      not String.match?(earlier, ~r/^\s*(def|defmacro|defguard)\s+#{name}\b/m)
    else
      _ -> false
    end
  end
end
