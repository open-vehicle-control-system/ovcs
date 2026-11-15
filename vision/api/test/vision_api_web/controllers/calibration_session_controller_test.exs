defmodule VisionApiWeb.CalibrationSessionControllerTest do
  use VisionApiWeb.CalibrationCase

  import VisionApiWeb.RefusalTests

  test_document_refusals("/api/calibration-sessions", "calibration-sessions")
  test_calibration_unit_refusals("/api/calibration-sessions", "calibration-sessions")

  alias VisionCore.Calibration.Session

  @media_type "application/vnd.api+json"

  describe "POST /api/calibration-sessions" do
    test "starts a session on the stereo pair, related to its calibration", %{conn: conn} do
      conn = post_document(conn, "/api/calibration-sessions", session())
      assert get_resp_header(conn, "content-type") == [@media_type]

      assert %{
               "data" => %{
                 "type" => "calibration-sessions",
                 "id" => id,
                 "attributes" => %{
                   "phase" => "capturing",
                   "board" => %{"columns" => 8, "rows" => 6, "squareMm" => 25.0},
                   "samples" => 0
                 },
                 "relationships" => %{
                   "calibration" => %{"data" => %{"type" => "calibrations", "id" => "unit"}}
                 }
               }
             } = json_response(conn, 201)

      assert is_binary(id)
    end

    test "starts a session on a camera of its own", %{conn: conn} do
      assert %{
               "data" => %{
                 "attributes" => %{"phase" => "capturing"},
                 "relationships" => %{"calibration" => %{"data" => %{"id" => "hq"}}}
               }
             } =
               conn
               |> post_document("/api/calibration-sessions", session("hq"))
               |> json_response(201)

      assert %{target: %{id: "hq", kind: :camera}} = Session.state()
    end

    test "starts a session on a camera's pose", %{conn: conn} do
      assert %{
               "data" => %{
                 "attributes" => %{"phase" => "capturing"},
                 "relationships" => %{"calibration" => %{"data" => %{"id" => "hq-pose"}}}
               }
             } =
               conn
               |> post_document("/api/calibration-sessions", session("hq-pose"))
               |> json_response(201)

      assert %{target: %{id: "hq-pose", kind: :pose}} = Session.state()
    end

    test "answers 422, naming it, for a pose whose camera has no calibration",
         %{conn: conn, tmp_dir: tmp_dir} do
      File.rm!(Path.join(tmp_dir, "hq.yaml"))

      conn = post_document(conn, "/api/calibration-sessions", session("hq-pose"))
      assert get_resp_header(conn, "content-type") == [@media_type]

      assert %{
               "errors" => [
                 %{
                   "status" => "422",
                   "title" => "Not started",
                   "detail" => "the hq camera has no calibration: calibrate it first"
                 }
               ]
             } = json_response(conn, 422)

      assert %{phase: :idle} = Session.state()
    end

    test "answers 400 without a calibration to work on, pointing at it", %{conn: conn} do
      for relationships <- [nil, %{}, %{calibration: %{data: %{type: "stages", id: "unit"}}}] do
        data = session() |> Map.delete(:relationships)
        data = if relationships, do: Map.put(data, :relationships, relationships), else: data

        conn = post_document(conn, "/api/calibration-sessions", data)
        assert get_resp_header(conn, "content-type") == [@media_type]

        assert %{
                 "errors" => [
                   %{
                     "status" => "400",
                     "source" => %{"pointer" => "/data/relationships/calibration"}
                   }
                 ]
               } = json_response(conn, 400)
      end

      assert %{phase: :idle} = Session.state()
    end

    test "answers 404 for a calibration the unit has not", %{conn: conn} do
      assert %{"errors" => [%{"status" => "404", "detail" => "no calibration rear"}]} =
               conn
               |> post_document("/api/calibration-sessions", session("rear"))
               |> json_response(404)
    end

    test "refuses a square board, a missing one and one without a size, as a 422", %{conn: conn} do
      for board <- [%{columns: 7, rows: 7, squareMm: 25}, nil, %{columns: 8, rows: 6}] do
        assert %{
                 "errors" => [
                   %{"status" => "422", "source" => %{"pointer" => "/data/attributes/board"}}
                 ]
               } =
                 conn
                 |> post_document("/api/calibration-sessions", session("unit", board))
                 |> json_response(422)
      end
    end

    test "refuses a board out of bounds as a 422, however large its numbers", %{conn: conn} do
      huge = Integer.pow(10, 400)

      for board <- [
            %{columns: 2, rows: 6, squareMm: 25},
            %{columns: huge, rows: 6, squareMm: 25},
            %{columns: 8, rows: 6, squareMm: huge},
            %{columns: 8, rows: 6, squareMm: 0},
            %{columns: 8, rows: 6, squareMm: "25"}
          ] do
        assert %{
                 "errors" => [
                   %{"status" => "422", "source" => %{"pointer" => "/data/attributes/board"}}
                 ]
               } =
                 conn
                 |> post_document("/api/calibration-sessions", session("unit", board))
                 |> json_response(422)
      end

      assert Session.state().phase == :idle
    end

    test "answers 409 while a session runs", %{conn: conn} do
      post_document(conn, "/api/calibration-sessions", session())

      assert %{"errors" => [%{"status" => "409", "detail" => detail}]} =
               conn
               |> post_document("/api/calibration-sessions", session("hq"))
               |> json_response(409)

      assert detail =~ "already running"
    end

    test "answers 422 while the cameras are down", %{conn: conn} do
      camera = Process.whereis(VisionApiWeb.CalibrationCase.Camera.name_for("unit/left"))
      monitor = Process.monitor(camera)
      Process.exit(camera, :kill)
      assert_receive {:DOWN, ^monitor, :process, ^camera, :killed}

      assert %{
               "errors" => [
                 %{"status" => "422", "detail" => "the stereo cameras are not running"}
               ]
             } =
               conn |> post_document("/api/calibration-sessions", session()) |> json_response(422)
    end

    test "carrying an id of the client's is forbidden, and does nothing", %{conn: conn} do
      data = Map.put(session(), :id, "mine")

      assert %{"errors" => [%{"status" => "403", "source" => %{"pointer" => "/data/id"}}]} =
               conn |> post_document("/api/calibration-sessions", data) |> json_response(403)

      assert %{phase: :idle} = Session.state()
    end
  end
end
