defmodule VisionApiWeb.ComposerSnippetControllerTest do
  use VisionApiWeb.ParametersCase

  test "GET /api/composer-snippet answers the saved values as a composer snippet", %{conn: conn} do
    conn = get(conn, "/api/composer-snippet")
    assert get_resp_header(conn, "content-type") == ["application/vnd.api+json"]

    assert %{
             "data" => %{
               "type" => "composer-snippets",
               "id" => "current",
               "attributes" => %{"snippet" => snippet}
             }
           } = json_response(conn, 200)

    assert snippet =~ "# Nothing saved."
  end
end
