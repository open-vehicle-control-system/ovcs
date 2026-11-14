defmodule VisionApiWeb.CoreUnavailableTest do
  use VisionApiWeb.ConnCase, async: false

  @media_type "application/vnd.api+json"

  setup do
    Application.stop(:vision_core)
    on_exit(fn -> Application.ensure_all_started(:vision_core) end)
  end

  defp document(type, extra \\ %{}), do: Jason.encode!(%{data: Map.merge(%{type: type}, extra)})

  defp parameter,
    do: document("parameters", %{id: "stereo.disparity.p1", attributes: %{value: 1}})

  for {method, path, body} <- [
        {:get, "/api/stages", nil},
        {:get, "/api/parameters", nil},
        {:get, "/api/parameters/stereo.disparity.p1", nil},
        {:patch, "/api/parameters/stereo.disparity.p1", :parameter},
        {:post, "/api/parameter-saves", "parameter-saves"},
        {:post, "/api/parameter-discards", "parameter-discards"},
        {:post, "/api/parameter-resets", "parameter-resets"}
      ] do
    test "#{method |> to_string() |> String.upcase()} #{path} answers a JSON:API 503 while the vision core does not run",
         %{conn: conn} do
      body =
        case unquote(body) do
          nil -> nil
          :parameter -> parameter()
          type -> document(type)
        end

      conn =
        conn
        |> put_req_header("content-type", @media_type)
        |> dispatch(@endpoint, unquote(method), unquote(path), body)

      assert get_resp_header(conn, "content-type") == [@media_type]

      assert json_response(conn, 503) == %{
               "errors" => [
                 %{
                   "status" => "503",
                   "title" => "Vision core unavailable",
                   "detail" => "the vision core does not run, or is restarting"
                 }
               ]
             }
    end
  end

  test "PATCH /api/saved-calibrations/:id with inUse answers a 503 while the vision core does not run",
       %{conn: conn} do
    id = "6f1c2a7e-3b4d-4e5f-8a9b-0c1d2e3f4a5b"
    body = document("saved-calibrations", %{id: id, attributes: %{inUse: true}})

    conn =
      conn
      |> put_req_header("content-type", @media_type)
      |> patch("/api/saved-calibrations/#{id}", body)

    assert %{"errors" => [%{"status" => "503"}]} = json_response(conn, 503)
  end
end
