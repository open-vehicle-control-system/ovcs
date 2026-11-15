defmodule VisionApiWeb.ParameterSaveControllerTest do
  use VisionApiWeb.ParametersCase

  import VisionApiWeb.RefusalTests

  test_document_refusals("/api/parameter-saves", "parameter-saves")

  test "POST /api/parameter-saves saves and lists what it saved", %{conn: conn} do
    set("test.disparity.p1", 12)
    assert unsaved(conn) == 1

    conn = post_document(conn, "/api/parameter-saves", %{type: "parameter-saves"})
    assert get_resp_header(conn, "content-type") == ["application/vnd.api+json"]

    assert %{
             "data" => %{
               "type" => "parameter-saves",
               "id" => id,
               "attributes" => %{"parameters" => ["test.disparity.p1"]}
             }
           } = json_response(conn, 201)

    assert is_binary(id)
    assert unsaved(conn) == 0
  end

  test "POST /api/parameter-saves answers 503 when the values cannot be saved", %{conn: conn} do
    :sys.replace_state(VisionCore.Parameters, &%{&1 | store: VisionApiWeb.FailingStore})
    set("test.disparity.p1", 12)

    conn = post_document(conn, "/api/parameter-saves", %{type: "parameter-saves"})

    assert %{
             "errors" => [
               %{
                 "status" => "503",
                 "title" => "Saved values unavailable",
                 "detail" => "saved parameters unavailable"
               }
             ]
           } = json_response(conn, 503)

    assert unsaved(conn) == 1
  end

  test "a save sent as a form, as another site's page can, is refused", %{conn: conn} do
    set("test.disparity.p1", 12)

    for {content_type, body} <- [
          {"application/x-www-form-urlencoded", "data[type]=parameter-saves"},
          {"text/plain", ~s({"data":{"type":"parameter-saves"}})}
        ] do
      assert %{"errors" => [%{"status" => "400"}]} =
               conn
               |> put_req_header("content-type", content_type)
               |> post("/api/parameter-saves", body)
               |> json_response(400)
    end

    assert unsaved(conn) == 1
  end

  test "a save carrying an id of the client's answers 403, and saves nothing", %{conn: conn} do
    set("test.disparity.p1", 12)

    conn = post_document(conn, "/api/parameter-saves", %{type: "parameter-saves", id: "mine"})

    assert %{"errors" => [%{"status" => "403", "source" => %{"pointer" => "/data/id"}}]} =
             json_response(conn, 403)

    assert unsaved(conn) == 1
  end
end
