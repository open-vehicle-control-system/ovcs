defmodule VisionApiWeb.ComposerSnippetPresenter do
  @moduledoc "The saved parameter values as a composer snippet, a `composer-snippets` singleton."
  alias VisionApiWeb.JsonApi

  @spec present(String.t()) :: map()
  def present(snippet), do: JsonApi.resource("composer-snippets", "current", %{snippet: snippet})
end
