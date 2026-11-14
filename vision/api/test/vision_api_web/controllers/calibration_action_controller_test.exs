defmodule VisionApiWeb.CalibrationActionControllerTest do
  use VisionApiWeb.CalibrationCase

  alias VisionCore.Calibration.Session

  @media_type "application/vnd.api+json"

  defp post_action(conn, path, data) do
    conn
    |> put_req_header("content-type", @media_type)
    |> post(path, Jason.encode!(%{data: data}))
  end

  defp target(id), do: %{calibration: %{data: %{type: "calibrations", id: id}}}

  defp session(id \\ "unit", board \\ %{columns: 8, rows: 6, squareMm: 25}),
    do: %{type: "calibration-sessions", attributes: %{board: board}, relationships: target(id)}

  defp capturing(%{conn: conn}) do
    conn |> post_action("/api/calibration-sessions", session()) |> json_response(201)
    :ok
  end

  defp solvable do
    :sys.replace_state(Session, &%{&1 | samples: good_samples(), size: {1280, 720}})
  end

  defp solved(result \\ solved_result()) do
    :sys.replace_state(Session, &%{&1 | phase: :solved, result: result, samples: good_samples()})
  end

  describe "POST /api/calibration-sessions" do
    test "starts a session on the stereo pair, related to its calibration", %{conn: conn} do
      conn = post_action(conn, "/api/calibration-sessions", session())
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
               |> post_action("/api/calibration-sessions", session("hq"))
               |> json_response(201)

      assert %{target: %{id: "hq", kind: :camera}} = Session.state()
    end

    test "answers 400 without a calibration to work on, pointing at it", %{conn: conn} do
      for relationships <- [nil, %{}, %{calibration: %{data: %{type: "stages", id: "unit"}}}] do
        data = session() |> Map.delete(:relationships)
        data = if relationships, do: Map.put(data, :relationships, relationships), else: data

        conn = post_action(conn, "/api/calibration-sessions", data)
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
               |> post_action("/api/calibration-sessions", session("rear"))
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
                 |> post_action("/api/calibration-sessions", session("unit", board))
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
                 |> post_action("/api/calibration-sessions", session("unit", board))
                 |> json_response(422)
      end

      assert Session.state().phase == :idle
    end

    test "answers 409 while a session runs", %{conn: conn} do
      post_action(conn, "/api/calibration-sessions", session())

      assert %{"errors" => [%{"status" => "409", "detail" => detail}]} =
               conn
               |> post_action("/api/calibration-sessions", session("hq"))
               |> json_response(409)

      assert detail =~ "already running"
    end

    test "answers 422 while the cameras are down", %{conn: conn} do
      Process.exit(Process.whereis(VisionApiWeb.CalibrationCase.Camera.name_for("left")), :kill)

      assert %{
               "errors" => [
                 %{"status" => "422", "detail" => "the stereo cameras are not running"}
               ]
             } =
               conn |> post_action("/api/calibration-sessions", session()) |> json_response(422)
    end
  end

  describe "an action" do
    test "with another type is a conflict", %{conn: conn} do
      conn = post_action(conn, "/api/calibration-solves", %{type: "calibration-cancels"})
      assert get_resp_header(conn, "content-type") == [@media_type]

      assert %{"errors" => [%{"status" => "409", "source" => %{"pointer" => "/data/type"}}]} =
               json_response(conn, 409)
    end

    test "carrying an id of the client's is forbidden, and does nothing", %{conn: conn} do
      data = Map.put(session(), :id, "mine")

      assert %{"errors" => [%{"status" => "403", "source" => %{"pointer" => "/data/id"}}]} =
               conn |> post_action("/api/calibration-sessions", data) |> json_response(403)

      assert %{phase: :idle} = Session.state()
    end

    test "sent as a form, or in the query string, is a bad request", %{conn: conn} do
      form =
        conn
        |> put_req_header("content-type", "application/x-www-form-urlencoded")
        |> post("/api/calibration-cancels", "data[type]=calibration-cancels")

      assert get_resp_header(form, "content-type") == [@media_type]
      assert %{"errors" => [%{"status" => "400"}]} = json_response(form, 400)

      assert %{"errors" => [%{"status" => "400"}]} =
               conn
               |> post("/api/calibration-cancels?data[type]=calibration-cancels")
               |> json_response(400)
    end

    test "answers 404 on a unit with nothing to calibrate, whatever its body", %{conn: conn} do
      VisionApiWeb.TestUnit.start(%VisionCore.Config{})

      for data <- [%{type: "calibration-cancels"}, %{type: "calibration-solves"}] do
        assert %{"errors" => [%{"status" => "404"}]} =
                 conn |> post_action("/api/calibration-cancels", data) |> json_response(404)
      end
    end

    test "answers 503 while the session is not running", %{conn: conn} do
      stop_supervised!(Session)

      assert %{"errors" => [%{"status" => "503"}]} =
               conn
               |> post_action("/api/calibration-cancels", %{type: "calibration-cancels"})
               |> json_response(503)
    end
  end

  test "POST /api/calibration-cancels ends the session", %{conn: conn} do
    post_action(conn, "/api/calibration-sessions", session())

    assert %{
             "data" => %{
               "type" => "calibration-cancels",
               "attributes" => %{"phase" => "idle"},
               "relationships" => %{"calibration" => %{"data" => nil}}
             }
           } =
             conn
             |> post_action("/api/calibration-cancels", %{type: "calibration-cancels"})
             |> json_response(201)
  end

  describe "with a session capturing" do
    setup :capturing

    test "POST /api/calibration-solves answers 422 before good enough", %{conn: conn} do
      assert %{"errors" => [%{"status" => "422", "title" => "Not solved"}]} =
               conn
               |> post_action("/api/calibration-solves", %{type: "calibration-solves"})
               |> json_response(422)
    end

    test "POST /api/calibration-solves answers 202 once the solve has begun, whose result carries the image size and each camera's YAML",
         %{conn: conn} do
      solvable()
      {:ok, _state} = Session.subscribe()

      assert %{"data" => %{"type" => "calibration-solves", "attributes" => %{"phase" => phase}}} =
               conn
               |> post_action("/api/calibration-solves", %{type: "calibration-solves"})
               |> json_response(202)

      assert phase in ["solving", "solved"]

      assert_receive {:calibration_session, %{phase: :solved} = state}

      assert %{
               result: %{
                 imageWidth: 1280,
                 imageHeight: 720,
                 stereoRmsPx: 0.5,
                 baselineM: 0.12,
                 cameras: [
                   %{name: "left", file: "unit_left.yaml", rmsPx: 0.3, yaml: left_yaml},
                   %{name: "right", file: "unit_right.yaml", rmsPx: 0.4, yaml: right_yaml}
                 ]
               }
             } = VisionApiWeb.CalibrationJSON.session(state)

      assert "image_width: 1280" <> _ = left_yaml
      assert left_yaml =~ "camera_name: unit_left"
      assert right_yaml =~ "camera_name: unit_right"
    end

    test "POST /api/calibration-applies answers 422 before a solve", %{conn: conn} do
      assert %{"errors" => [%{"status" => "422", "title" => "Not applied"}]} =
               conn
               |> post_action("/api/calibration-applies", %{type: "calibration-applies"})
               |> json_response(422)
    end

    test "POST /api/calibration-applies answers 202 with the session applying, and a cancel is a conflict",
         %{conn: conn} do
      solved()

      applied = post_action(conn, "/api/calibration-applies", %{type: "calibration-applies"})
      assert get_resp_header(applied, "content-type") == [@media_type]

      assert %{"data" => %{"attributes" => %{"phase" => "applying"}}} =
               json_response(applied, 202)

      assert_receive {:commit, commit}

      assert %{"errors" => [%{"status" => "409", "detail" => "the calibration is being applied"}]} =
               conn
               |> post_action("/api/calibration-cancels", %{type: "calibration-cancels"})
               |> json_response(409)

      send(commit, :go)
    end
  end

  test "a camera's solve gives its one calibration, and its apply commits it", %{conn: conn} do
    conn |> post_action("/api/calibration-sessions", session("hq")) |> json_response(201)
    solved(solved_camera_result())

    assert %{
             result: %{
               imageWidth: 1280,
               imageHeight: 720,
               stereoRmsPx: nil,
               baselineM: nil,
               fxPx: 880.0,
               cameras: [%{name: "hq", file: "hq.yaml", rmsPx: 0.2, yaml: yaml}]
             }
           } = VisionApiWeb.CalibrationJSON.session(Session.state())

    assert yaml =~ "camera_name: hq"

    conn
    |> post_action("/api/calibration-applies", %{type: "calibration-applies"})
    |> json_response(202)

    assert_receive {:commit_camera, :hq}
  end

  describe "POST /api/calibration-resets" do
    defp reset(id), do: %{type: "calibration-resets", relationships: target(id)}

    test "returns the stereo pair to its built-in calibration",
         %{conn: conn, config: config, tmp_dir: tmp_dir} do
      store = Path.join(tmp_dir, "store")
      File.mkdir_p!(store)

      config =
        update_in(config.components[:stereo], &Keyword.put(&1, :calibration_store_dir, store))

      :persistent_term.put({VisionCore.Application, :active_config}, config)

      {:ok, cameras} = VisionCore.Stereo.Supervisor.camera_options(config)

      for side <- [:left, :right] do
        File.write!(
          cameras[side][:calibration_store_path],
          VisionCore.Ros2.CameraCalibration.to_yaml(
            VisionApiWeb.CalibrationCase.calibration(),
            "stored"
          )
        )
      end

      # Answers the reload of the stereo pipeline.
      pipeline =
        spawn_link(fn ->
          for _call <- 1..2 do
            receive do
              {:"$gen_call", from, {:reload_calibration, _paths}} -> GenServer.reply(from, :ok)
              {:"$gen_call", from, :stage_options} -> GenServer.reply(from, [])
            end
          end
        end)

      Process.register(pipeline, VisionCore.Stereo.Pipeline)

      assert %{"data" => %{"attributes" => %{"source" => "stored", "canReset" => true}}} =
               conn |> get("/api/calibrations/unit") |> json_response(200)

      assert %{"data" => %{"type" => "calibration-resets"}} =
               conn |> post_action("/api/calibration-resets", reset("unit")) |> json_response(201)

      assert %{"data" => %{"attributes" => %{"source" => "builtIn", "canReset" => false}}} =
               conn |> get("/api/calibrations/unit") |> json_response(200)
    end

    test "returns a camera to its built-in calibration", %{conn: conn, config: config} do
      :ok =
        VisionCore.Camera.Calibration.commit(
          config,
          :hq,
          %{VisionApiWeb.CalibrationCase.calibration() | width: 640}
        )

      assert %{"data" => %{"attributes" => %{"source" => "stored", "canReset" => true}}} =
               conn |> get("/api/calibrations/hq") |> json_response(200)

      conn |> post_action("/api/calibration-resets", reset("hq")) |> json_response(201)

      assert %{"data" => %{"attributes" => %{"source" => "builtIn"}}} =
               conn |> get("/api/calibrations/hq") |> json_response(200)
    end

    test "answers 422 when nothing is stored", %{conn: conn} do
      for id <- ["unit", "hq"] do
        assert %{"errors" => [%{"status" => "422", "title" => "Not reset"}]} =
                 conn |> post_action("/api/calibration-resets", reset(id)) |> json_response(422)
      end
    end

    test "answers 422 without a built-in calibration to return to", %{conn: conn, config: config} do
      :ok =
        VisionCore.Camera.Calibration.commit(
          config,
          :hq,
          VisionApiWeb.CalibrationCase.calibration()
        )

      File.rm!(config.components[:camera][:calibration])

      assert %{"errors" => [%{"status" => "422", "title" => "Not reset", "detail" => detail}]} =
               conn |> post_action("/api/calibration-resets", reset("hq")) |> json_response(422)

      assert detail =~ "no built-in calibration"
    end

    @tag :capture_log
    test "answers 500 when the unit does not take the built-in calibration, the stored one kept",
         %{conn: conn, config: config, tmp_dir: tmp_dir} do
      store = Path.join(tmp_dir, "store")
      File.mkdir_p!(store)

      config =
        update_in(config.components[:stereo], &Keyword.put(&1, :calibration_store_dir, store))

      :persistent_term.put({VisionCore.Application, :active_config}, config)
      {:ok, cameras} = VisionCore.Stereo.Supervisor.camera_options(config)

      for side <- [:left, :right],
          do: File.write!(cameras[side][:calibration_store_path], "stored #{side}")

      # Refuses the reload of the stereo pipeline.
      pipeline =
        spawn_link(fn ->
          receive do
            {:"$gen_call", from, {:reload_calibration, _paths}} ->
              GenServer.reply(from, {:error, :does_not_fit})
          end
        end)

      Process.register(pipeline, VisionCore.Stereo.Pipeline)

      reset = post_action(conn, "/api/calibration-resets", reset("unit"))
      assert get_resp_header(reset, "content-type") == [@media_type]
      assert %{"errors" => [%{"status" => "500", "detail" => detail}]} = json_response(reset, 500)
      assert detail =~ "does_not_fit"
      assert File.read!(cameras[:left][:calibration_store_path]) == "stored left"
    end

    test "answers 400 without a calibration to reset, and 404 for one the unit has not",
         %{conn: conn} do
      assert %{
               "errors" => [
                 %{
                   "status" => "400",
                   "source" => %{"pointer" => "/data/relationships/calibration"}
                 }
               ]
             } =
               conn
               |> post_action("/api/calibration-resets", %{type: "calibration-resets"})
               |> json_response(400)

      assert %{"errors" => [%{"status" => "404"}]} =
               conn |> post_action("/api/calibration-resets", reset("rear")) |> json_response(404)
    end
  end
end
