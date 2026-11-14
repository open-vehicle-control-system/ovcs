defmodule VisionApiWeb.ParameterDiscardControllerTest do
  use VisionApiWeb.ParametersCase

  import VisionApiWeb.RefusalTests

  test_document_refusals("/api/parameter-discards", "parameter-discards")

  test "POST /api/parameter-discards puts unsaved changes back", %{conn: conn} do
    set("test.disparity.p1", 12)

    conn = post_document(conn, "/api/parameter-discards", %{type: "parameter-discards"})

    assert %{
             "data" => %{
               "type" => "parameter-discards",
               "attributes" => %{"parameters" => ["test.disparity.p1"]}
             }
           } = json_response(conn, 201)

    assert %{"attributes" => %{"value" => 8}} = parameter(conn, "test.disparity.p1")
  end

  test "a discard carrying an id of the client's answers 403, and discards nothing",
       %{conn: conn} do
    set("test.disparity.p1", 12)

    conn =
      post_document(conn, "/api/parameter-discards", %{type: "parameter-discards", id: "mine"})

    assert %{"errors" => [%{"status" => "403", "source" => %{"pointer" => "/data/id"}}]} =
             json_response(conn, 403)

    assert unsaved(conn) == 1
    assert %{"attributes" => %{"value" => 12}} = parameter(conn, "test.disparity.p1")
  end
end
