defmodule VisionApiWeb.ComposerSnippetController do
  @moduledoc """
  The saved parameter values as a composer snippet
  (`VisionCore.Parameters.export/0`), a read-only `composer-snippets`
  singleton.
  """
  use VisionApiWeb, :controller

  alias VisionApiWeb.JsonApi
  alias VisionCore.Parameters

  def show(conn, _params) do
    snippet = JsonApi.resource("composer-snippets", "current", %{snippet: Parameters.export()})
    JsonApi.send_document(conn, 200, %{data: snippet})
  end
end
