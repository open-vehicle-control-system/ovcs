defmodule VisionApiWeb.CalibrationActionControllerTest do
  use VisionApiWeb.CalibrationCase

  alias VisionCore.Calibration.Session

  defp post_action(conn, path, data) do
    conn
    |> put_req_header("content-type", "application/vnd.api+json")
    |> post(path, Jason.encode!(%{data: data}))
  end

  defp board(columns \\ 8, rows \\ 6, square_mm \\ 25),
    do: %{
      type: "calibration-sessions",
      attributes: %{board: %{columns: columns, rows: rows, squareMm: square_mm}}
    }

  defp capturing(%{conn: conn}) do
    conn |> post_action("/api/calibration-sessions", board()) |> json_response(201)
    :ok
  end

  defp solvable do
    :sys.replace_state(Session, &%{&1 | samples: good_samples(), size: {1280, 720}})
  end

  defp solved do
    :sys.replace_state(
      Session,
      &%{&1 | phase: :solved, result: solved_result(), samples: good_samples()}
    )
  end

  test "POST /api/calibration-sessions starts a session", %{conn: conn} do
    conn = post_action(conn, "/api/calibration-sessions", board())
    assert get_resp_header(conn, "content-type") == ["application/vnd.api+json"]

    assert %{
             "data" => %{
               "type" => "calibration-sessions",
               "id" => id,
               "attributes" => %{
                 "phase" => "capturing",
                 "board" => %{"columns" => 8, "rows" => 6, "squareMm" => 25.0},
                 "samples" => 0
               }
             }
           } = json_response(conn, 201)

    assert is_binary(id)
  end

  test "POST /api/calibration-sessions refuses a square board", %{conn: conn} do
    assert %{
             "errors" => [
               %{"status" => "422", "source" => %{"pointer" => "/data/attributes/board"}}
             ]
           } =
             conn
             |> post_action("/api/calibration-sessions", board(7, 7))
             |> json_response(422)
  end

  test "POST /api/calibration-sessions refuses a missing board and a missing size", %{conn: conn} do
    for data <- [
          %{type: "calibration-sessions"},
          %{type: "calibration-sessions", attributes: %{board: %{columns: 8, rows: 6}}}
        ] do
      assert %{"errors" => [%{"status" => "422"}]} =
               conn |> post_action("/api/calibration-sessions", data) |> json_response(422)
    end
  end

  test "POST /api/calibration-sessions answers 409 while a session runs", %{conn: conn} do
    post_action(conn, "/api/calibration-sessions", board())

    assert %{"errors" => [%{"status" => "409", "detail" => detail}]} =
             conn |> post_action("/api/calibration-sessions", board()) |> json_response(409)

    assert detail =~ "already running"
  end

  test "POST /api/calibration-sessions answers 422 while the cameras are down", %{conn: conn} do
    Process.exit(Process.whereis(VisionApiWeb.CalibrationCase.Camera.name_for("left")), :kill)

    assert %{"errors" => [%{"status" => "422", "detail" => "the stereo cameras are not running"}]} =
             conn |> post_action("/api/calibration-sessions", board()) |> json_response(422)
  end

  test "an action with another type is a conflict", %{conn: conn} do
    assert %{"errors" => [%{"status" => "409", "source" => %{"pointer" => "/data/type"}}]} =
             conn
             |> post_action("/api/calibration-solves", %{type: "calibration-cancels"})
             |> json_response(409)
  end

  test "an action sent as a form is a bad request", %{conn: conn} do
    assert %{"errors" => [%{"status" => "400"}]} =
             conn
             |> put_req_header("content-type", "application/x-www-form-urlencoded")
             |> post("/api/calibration-cancels", "data[type]=calibration-cancels")
             |> json_response(400)
  end

  test "POST /api/calibration-cancels ends the session", %{conn: conn} do
    post_action(conn, "/api/calibration-sessions", board())

    assert %{"data" => %{"type" => "calibration-cancels", "attributes" => %{"phase" => "idle"}}} =
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

    test "POST /api/calibration-solves starts the solve, whose result carries the YAML",
         %{conn: conn} do
      solvable()
      {:ok, _state} = Session.subscribe()

      assert %{
               "data" => %{
                 "type" => "calibration-solves",
                 "attributes" => %{"phase" => phase}
               }
             } =
               conn
               |> post_action("/api/calibration-solves", %{type: "calibration-solves"})
               |> json_response(201)

      assert phase in ["solving", "solved"]

      assert_receive {:calibration_session, %{phase: :solved} = state}

      assert %{
               result: %{
                 stereoRmsPx: 0.5,
                 baselineM: 0.12,
                 left: %{yaml: "image_width: 1280" <> _ = left_yaml},
                 right: %{yaml: right_yaml}
               }
             } = VisionApiWeb.CalibrationJSON.session(state, "unit")

      assert left_yaml =~ "camera_name: unit_left"
      assert right_yaml =~ "camera_name: unit_right"
    end

    test "POST /api/calibration-applies answers 422 before a solve", %{conn: conn} do
      assert %{"errors" => [%{"status" => "422", "title" => "Not applied"}]} =
               conn
               |> post_action("/api/calibration-applies", %{type: "calibration-applies"})
               |> json_response(422)
    end

    test "POST /api/calibration-applies answers at once with the session applying, and a cancel is a conflict",
         %{conn: conn} do
      solved()

      assert %{"data" => %{"attributes" => %{"phase" => "applying"}}} =
               conn
               |> post_action("/api/calibration-applies", %{type: "calibration-applies"})
               |> json_response(201)

      assert_receive {:commit, commit}

      assert %{"errors" => [%{"status" => "409", "detail" => "the calibration is being applied"}]} =
               conn
               |> post_action("/api/calibration-cancels", %{type: "calibration-cancels"})
               |> json_response(409)

      send(commit, :go)
    end
  end

  test "POST /api/calibration-resets goes back to the built-in calibration",
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
             conn |> get("/api/calibration") |> json_response(200)

    assert %{"data" => %{"type" => "calibration-resets"}} =
             conn
             |> post_action("/api/calibration-resets", %{type: "calibration-resets"})
             |> json_response(201)

    assert %{"data" => %{"attributes" => %{"source" => "builtIn", "canReset" => false}}} =
             conn |> get("/api/calibration") |> json_response(200)
  end

  test "an action sent in the query string is a bad request", %{conn: conn} do
    assert %{"errors" => [%{"status" => "400"}]} =
             conn
             |> post("/api/calibration-cancels?data[type]=calibration-cancels")
             |> json_response(400)
  end

  test "POST /api/calibration-resets answers 422 when nothing is stored", %{conn: conn} do
    assert %{"errors" => [%{"status" => "422", "title" => "Not reset"}]} =
             conn
             |> post_action("/api/calibration-resets", %{type: "calibration-resets"})
             |> json_response(422)
  end

  test "an action answers 404 on a unit without a :stereo component, whatever its body",
       %{conn: conn} do
    VisionApiWeb.TestUnit.start(%VisionCore.Config{})

    for data <- [%{type: "calibration-cancels"}, %{type: "calibration-solves"}] do
      assert %{"errors" => [%{"status" => "404"}]} =
               conn
               |> post_action("/api/calibration-cancels", data)
               |> json_response(404)
    end
  end

  test "an action answers 503 while the session is not running", %{conn: conn} do
    stop_supervised!(Session)

    assert %{"errors" => [%{"status" => "503"}]} =
             conn
             |> post_action("/api/calibration-cancels", %{type: "calibration-cancels"})
             |> json_response(503)
  end
end
