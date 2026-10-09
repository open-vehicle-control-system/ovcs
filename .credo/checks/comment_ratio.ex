defmodule Ovcs.Credo.Check.CommentRatio do
  use Credo.Check,
    id: "OVCS002",
    base_priority: :normal,
    category: :readability,
    param_defaults: [max_ratio: 0.25, allowance: 3],
    explanations: [
      check: """
      A file's comment lines stay under `max_ratio` of its code lines,
      plus `allowance` lines (CODE_STYLING.md, "Names, docs and
      comments"). `@moduledoc` and `@doc` text does not count.

      A file over the cap explains with comments what its names and
      docs should: rename, extract well-named functions, or move the
      explanation into `@moduledoc`.
      """,
      params: [
        max_ratio: "Comment lines allowed per code line.",
        allowance: "Comment lines allowed on top of the ratio."
      ]
    ]

  alias Ovcs.Credo.Comments

  @doc false
  @impl true
  def run(%SourceFile{} = source_file, params) do
    max_ratio = Params.get(params, :max_ratio, __MODULE__)
    allowance = Params.get(params, :allowance, __MODULE__)
    {blocks, code_lines} = Comments.parse(source_file)

    comments = Enum.sum(for {_, lines, _} <- blocks, do: length(lines))
    code = length(code_lines)
    cap = trunc(code * max_ratio) + allowance

    if comments > cap do
      [
        format_issue(IssueMeta.for(source_file, params),
          message: "#{comments} comment lines for #{code} code lines, at most #{cap}.",
          line_no: 1
        )
      ]
    else
      []
    end
  end
end
