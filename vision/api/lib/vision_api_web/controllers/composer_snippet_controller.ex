defmodule VisionApiWeb.ComposerSnippetController do
  @moduledoc """
  The saved parameter values as a composer snippet
  (`VisionCore.Parameters.export/0`), a read-only `composer-snippets`
  singleton.
  """
  use VisionApiWeb, :controller

  alias VisionApiWeb.{ComposerSnippetPresenter, JsonApi}
  alias VisionCore.Parameters

  def show(conn, _params) do
    snippet = ComposerSnippetPresenter.present(Parameters.export())
    JsonApi.send_document(conn, 200, %{data: snippet})
  end
end
