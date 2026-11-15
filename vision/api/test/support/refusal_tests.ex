defmodule VisionApiWeb.RefusalTests do
  @moduledoc """
  Tests the refusals every route creating a resource the unit names
  makes, those every route changing a resource makes, and those every
  calibration action makes, generated for one route in the module that
  calls them. The module uses
  `VisionApiWeb.ConnCase`, and `VisionApiWeb.CalibrationCase` for the
  calibration actions.
  """

  @media_type "application/vnd.api+json"

  @doc """
  Tests that `POST path` refuses a document of another type than `type`
  (409), one without data (400), one sent as a form or in the query
  string (400), and one carrying an id of the client's (403).
  """
  defmacro test_document_refusals(path, type) do
    quote do
      test "POST #{unquote(path)} answers 409 for another type, and 400 without data",
           %{conn: conn} do
        conflict = post_document(conn, unquote(path), %{type: "widgets"})
        assert get_resp_header(conflict, "content-type") == [unquote(@media_type)]

        assert %{"errors" => [%{"status" => "409", "source" => %{"pointer" => "/data/type"}}]} =
                 json_response(conflict, 409)

        assert %{"errors" => [%{"status" => "400", "source" => %{"pointer" => "/data"}}]} =
                 conn
                 |> put_req_header("content-type", unquote(@media_type))
                 |> post(unquote(path), "{}")
                 |> json_response(400)
      end

      test "POST #{unquote(path)} refuses a document sent as a form or in the query string, as another site's page can",
           %{conn: conn} do
        for {content_type, path, body} <- [
              {"application/x-www-form-urlencoded", unquote(path), "data[type]=#{unquote(type)}"},
              {"text/plain", unquote(path), ~s({"data":{"type":"#{unquote(type)}"}})},
              {nil, "#{unquote(path)}?data[type]=#{unquote(type)}", nil}
            ] do
          conn =
            if content_type, do: put_req_header(conn, "content-type", content_type), else: conn

          refused = post(conn, path, body)
          assert get_resp_header(refused, "content-type") == [unquote(@media_type)]
          assert %{"errors" => [%{"status" => "400"}]} = json_response(refused, 400)
        end
      end

      test "POST #{unquote(path)} answers 403 for a document carrying an id of the client's",
           %{conn: conn} do
        conn = post_document(conn, unquote(path), %{type: unquote(type), id: "mine"})

        assert %{"errors" => [%{"status" => "403", "source" => %{"pointer" => "/data/id"}}]} =
                 json_response(conn, 403)
      end
    end
  end

  @doc """
  Tests that `PATCH path`, the resource of `type` and `id`, refuses a
  document of another type (409), another id (409), one without data
  (400), and one sent as a form or in the query string (400).
  """
  defmacro test_change_refusals(path, type, id) do
    quote do
      test "PATCH #{unquote(path)} answers 409 for another type or id, and 400 without data",
           %{conn: conn} do
        for {data, pointer} <- [
              {%{type: "widgets", id: unquote(id)}, "/data/type"},
              {%{type: unquote(type), id: "another"}, "/data/id"}
            ] do
          conflict =
            conn
            |> put_req_header("content-type", unquote(@media_type))
            |> patch(unquote(path), Jason.encode!(%{data: data}))

          assert get_resp_header(conflict, "content-type") == [unquote(@media_type)]

          assert %{"errors" => [%{"status" => "409", "source" => %{"pointer" => ^pointer}}]} =
                   json_response(conflict, 409)
        end

        assert %{"errors" => [%{"status" => "400", "source" => %{"pointer" => "/data"}}]} =
                 conn
                 |> put_req_header("content-type", unquote(@media_type))
                 |> patch(unquote(path), "{}")
                 |> json_response(400)
      end

      test "PATCH #{unquote(path)} refuses a document sent as a form or in the query string",
           %{conn: conn} do
        for {content_type, path, body} <- [
              {"application/x-www-form-urlencoded", unquote(path),
               "data[type]=#{unquote(type)}&data[id]=#{unquote(id)}"},
              {nil, "#{unquote(path)}?data[type]=#{unquote(type)}&data[id]=#{unquote(id)}", nil}
            ] do
          conn =
            if content_type, do: put_req_header(conn, "content-type", content_type), else: conn

          refused = patch(conn, path, body)
          assert get_resp_header(refused, "content-type") == [unquote(@media_type)]
          assert %{"errors" => [%{"status" => "400"}]} = json_response(refused, 400)
        end
      end
    end
  end

  @doc """
  Tests that `POST path`, a calibration action of `type`, answers 404 on
  a unit with nothing to calibrate and 503 while the calibration session
  does not run, whatever its document.
  """
  defmacro test_calibration_unit_refusals(path, type) do
    quote do
      test "POST #{unquote(path)} answers 404 on a unit with nothing to calibrate, whatever its document",
           %{conn: conn} do
        VisionApiWeb.TestUnit.start(%VisionCore.Config{})

        for data <- [%{type: unquote(type)}, %{type: "widgets"}] do
          assert %{"errors" => [%{"status" => "404"}]} =
                   conn |> post_document(unquote(path), data) |> json_response(404)
        end
      end

      test "POST #{unquote(path)} answers 503 while the calibration session is not running",
           %{conn: conn} do
        stop_supervised!(VisionCore.Calibration.Session)

        assert %{"errors" => [%{"status" => "503", "title" => "Calibration unavailable"}]} =
                 conn
                 |> post_document(unquote(path), %{type: unquote(type)})
                 |> json_response(503)
      end
    end
  end
end
