defmodule VisionApiWeb.SavedCalibrationControllerTest do
  use VisionApiWeb.CalibrationCase

  alias VisionCore.Calibration.{Library, Recorder}
  alias VisionCore.Camera.Calibration, as: OwnCalibration
  alias VisionCore.Models
  alias VisionCore.Repo
  alias VisionCore.Ros2.CameraCalibration

  @unknown "6f1c2a7e-3b4d-4e5f-8a9b-0c1d2e3f4a5b"

  setup %{config: config} do
    for model <- [Models.StereoCameraCalibration, Models.CameraCalibration, Models.CameraPose],
        do: Repo.delete_all(model)

    start_supervised!({Recorder, config: config})
    :ok
  end

  defp calibration(fx) do
    built_in = VisionApiWeb.CalibrationCase.calibration()
    [_fx | rest] = built_in.camera_matrix
    %{built_in | camera_matrix: [fx | rest]}
  end

  # Commits a calibration of the camera `hq`, which the recorder saves and puts in use.
  defp save(config, fx, options \\ nil) do
    if options, do: Recorder.expect("hq", [{"hq", calibration(fx)}], {:record, options})
    :ok = OwnCalibration.commit(config, :hq, calibration(fx))
    :sys.get_state(Recorder)
    hd(Library.list("hq"))
  end

  defp jsonapi(conn),
    do: put_req_header(conn, "content-type", "application/vnd.api+json")

  defp rename(conn, id, document),
    do: conn |> jsonapi() |> patch("/api/saved-calibrations/#{id}", Jason.encode!(document))

  defp patch_saved(conn, id, attributes) do
    document = %{data: %{type: "saved-calibrations", id: id, attributes: attributes}}
    conn |> jsonapi() |> patch("/api/saved-calibrations/#{id}", Jason.encode!(document))
  end

  defp put_in_use(conn, id), do: patch_saved(conn, id, %{inUse: true})

  defp await_calibration_task do
    case Task.Supervisor.children(VisionCore.Calibration.Tasks) do
      [task] ->
        task

      [] ->
        receive do
        after
          5 -> await_calibration_task()
        end
    end
  end

  defp reset(conn, target) do
    document = %{
      data: %{
        type: "calibration-resets",
        relationships: %{calibration: %{data: %{type: "calibrations", id: target}}}
      }
    }

    conn |> jsonapi() |> post("/api/calibration-resets", Jason.encode!(document))
  end

  describe "GET /api/saved-calibrations" do
    test "lists the saved calibrations of every target, the newest first, with the one in use",
         %{conn: conn, config: config} do
      first = save(config, 580.8)

      second =
        save(config, 590.0,
          origin: "dashboard",
          board: %{columns: 8, rows: 6, square_m: 0.03},
          samples: 41,
          rms_px: %{"hq" => 0.2}
        )

      conn = get(conn, "/api/saved-calibrations")
      assert get_resp_header(conn, "content-type") == ["application/vnd.api+json"]
      assert %{"data" => [newest, oldest]} = json_response(conn, 200)

      assert %{
               "type" => "saved-calibrations",
               "id" => id,
               "attributes" => %{
                 "name" => name,
                 "origin" => "dashboard",
                 "createdAt" => created_at,
                 "inUse" => true,
                 "board" => %{"columns" => 8, "rows" => 6, "squareMm" => 30.0},
                 "samples" => 41,
                 "stereoRmsPx" => nil,
                 "baselineM" => nil,
                 "cameras" => [
                   %{
                     "name" => "hq",
                     "imageWidth" => 1280,
                     "imageHeight" => 720,
                     "fx" => 590.0,
                     "fy" => 910.0,
                     "cx" => 640.0,
                     "cy" => 360.0,
                     "distortion" => distortion,
                     "rmsPx" => 0.2,
                     "file" => "hq.yaml",
                     "yaml" => yaml
                   }
                 ]
               },
               "relationships" => %{
                 "calibration" => %{"data" => %{"type" => "calibrations", "id" => "hq"}}
               }
             } = newest

      assert id == second.id
      assert name == second.name
      assert distortion == [0.1, -0.2, 0.0, 0.0, 0.0]
      assert yaml == CameraCalibration.to_yaml(calibration(590.0), "hq")
      assert {:ok, _time, 0} = DateTime.from_iso8601(created_at)

      assert %{
               "id" => oldest_id,
               "attributes" => %{"origin" => "imported", "inUse" => false, "board" => nil}
             } =
               oldest

      assert oldest_id == first.id
    end

    test "gives a pair's cameras the files of the calibration in use, under the stereo unit's prefix",
         %{conn: conn, prefix: prefix} do
      {:ok, _pair} =
        Library.record(prefix, [{"left", calibration(580.8)}, {"right", calibration(590.0)}],
          origin: "dashboard"
        )

      assert %{"data" => [%{"attributes" => %{"cameras" => [left, right]}}]} =
               conn
               |> get("/api/saved-calibrations?filter[calibration]=#{prefix}")
               |> json_response(200)

      assert %{"name" => "left", "file" => "unit_left.yaml", "yaml" => left_yaml} = left
      assert %{"name" => "right", "file" => "unit_right.yaml", "yaml" => right_yaml} = right
      assert left_yaml == CameraCalibration.to_yaml(calibration(580.8), "unit_left")
      assert {:ok, %{camera_matrix: [590.0 | _rest]}} = CameraCalibration.parse(right_yaml)
    end

    test "gives a pose its rotation, translation, distance and error, and the file to save its YAML under",
         %{conn: conn, config: config} do
      pose = VisionApiWeb.CalibrationCase.pose()
      Recorder.expect("hq-pose", pose, {:record, origin: "dashboard", samples: 30, rms_px: 0.4})
      :ok = VisionCore.Camera.Pose.commit(config, :hq, pose)
      :sys.get_state(Recorder)

      conn = get(conn, "/api/saved-calibrations?filter[calibration]=hq-pose")
      assert get_resp_header(conn, "content-type") == ["application/vnd.api+json"]

      assert %{
               "data" => [
                 %{
                   "type" => "saved-calibrations",
                   "attributes" => %{
                     "origin" => "dashboard",
                     "inUse" => true,
                     "samples" => 30,
                     "cameras" => [],
                     "pose" => %{
                       "rotation" => [0.999 | _],
                       "translation" => translation,
                       "distanceMm" => distance_mm,
                       "rmsPx" => 0.4,
                       "file" => "hq_pose.yaml",
                       "yaml" => yaml
                     }
                   },
                   "relationships" => %{"calibration" => %{"data" => %{"id" => "hq-pose"}}}
                 }
               ]
             } = json_response(conn, 200)

      assert translation == pose.translation
      assert_in_delta distance_mm, 60.53, 0.01
      assert VisionCore.Camera.Pose.parse(yaml) == {:ok, pose}

      save(config, 580.8)

      assert %{"data" => [%{"attributes" => %{"pose" => nil}}]} =
               conn |> get("/api/saved-calibrations?filter[calibration]=hq") |> json_response(200)
    end

    test "lists one target's with filter[calibration], and none for a target without any",
         %{conn: conn, config: config} do
      save(config, 580.8)

      assert %{"data" => [_one]} =
               conn |> get("/api/saved-calibrations?filter[calibration]=hq") |> json_response(200)

      assert conn |> get("/api/saved-calibrations?filter[calibration]=unit") |> json_response(200) ==
               %{"data" => []}

      assert conn |> get("/api/saved-calibrations?filter[calibration]=rear") |> json_response(200) ==
               %{"data" => []}
    end

    test "answers 400 for a filter that is not one calibration's id, naming the parameter",
         %{conn: conn} do
      for {query, parameter} <- [
            {"filter[calibration][]=hq", "filter[calibration]"},
            {"filter[target]=hq", "filter[target]"},
            {"filter[calibration]=hq&filter[origin]=dashboard", "filter[origin]"},
            {"filter=hq", "filter"}
          ] do
        assert %{"errors" => [%{"status" => "400", "source" => %{"parameter" => ^parameter}}]} =
                 conn |> get("/api/saved-calibrations?#{query}") |> json_response(400)
      end
    end
  end

  describe "GET /api/saved-calibrations/:id" do
    test "renders one saved calibration", %{conn: conn, config: config} do
      saved = save(config, 580.8)

      assert %{"data" => %{"id" => id, "attributes" => %{"inUse" => true}}} =
               conn |> get("/api/saved-calibrations/#{saved.id}") |> json_response(200)

      assert id == saved.id
      assert Ecto.UUID.cast(id) == {:ok, id}
    end

    test "answers 404 for one the unit has not saved, or an id that names none", %{conn: conn} do
      for id <- [@unknown, "999999", "abc", "camera-1"] do
        assert %{"errors" => [%{"status" => "404", "detail" => detail}]} =
                 conn |> get("/api/saved-calibrations/#{id}") |> json_response(404)

        assert detail == "no saved calibration #{id}"
      end
    end

    test "answers 404 for an id written another way than the unit writes it",
         %{conn: conn, config: config} do
      id = save(config, 580.8).id

      for other <- [String.upcase(id), String.replace(id, "-", ""), "{#{id}}", "#{id}0"] do
        assert conn |> get("/api/saved-calibrations/#{other}") |> json_response(404)
        assert conn |> delete("/api/saved-calibrations/#{other}") |> json_response(404)

        document = %{data: %{type: "saved-calibrations", id: other, attributes: %{name: "x"}}}
        assert conn |> rename(other, document) |> json_response(404)

        assert conn |> put_in_use(other) |> json_response(404)
      end

      assert {:ok, _saved} = Library.fetch(id)
    end
  end

  describe "PATCH /api/saved-calibrations/:id" do
    test "names a calibration", %{conn: conn, config: config} do
      saved = save(config, 580.8)
      id = saved.id

      document = %{data: %{type: "saved-calibrations", id: id, attributes: %{name: " Workshop "}}}

      assert %{"data" => %{"id" => ^id, "attributes" => %{"name" => "Workshop"}}} =
               conn |> rename(id, document) |> json_response(200)

      assert {:ok, %{name: "Workshop"}} = Library.fetch(saved.id)
    end

    test "answers 422 for a name that is empty or too long", %{conn: conn, config: config} do
      id = save(config, 580.8).id

      for name <- ["   ", String.duplicate("a", 81)] do
        document = %{data: %{type: "saved-calibrations", id: id, attributes: %{name: name}}}

        assert %{
                 "errors" => [
                   %{
                     "status" => "422",
                     "title" => "Invalid name",
                     "source" => %{"pointer" => "/data/attributes/name"}
                   }
                 ]
               } = conn |> rename(id, document) |> json_response(422)
      end
    end

    test "answers 400 without a name, 409 for another type or id, 404 for one not saved",
         %{conn: conn, config: config} do
      id = save(config, 580.8).id

      assert conn
             |> rename(id, %{data: %{type: "saved-calibrations", id: id, attributes: %{name: 3}}})
             |> json_response(400)

      assert conn
             |> rename(id, %{data: %{type: "calibrations", id: id, attributes: %{name: "x"}}})
             |> json_response(409)

      assert conn
             |> rename(id, %{
               data: %{type: "saved-calibrations", id: "0", attributes: %{name: "x"}}
             })
             |> json_response(409)

      assert conn
             |> rename(@unknown, %{
               data: %{type: "saved-calibrations", id: @unknown, attributes: %{name: "x"}}
             })
             |> json_response(404)
    end

    test "answers 400 for a form body", %{conn: conn, config: config} do
      id = save(config, 580.8).id

      conn =
        conn
        |> put_req_header("content-type", "application/x-www-form-urlencoded")
        |> patch("/api/saved-calibrations/#{id}", "data[type]=saved-calibrations")

      assert json_response(conn, 400)
    end
  end

  describe "DELETE /api/saved-calibrations/:id" do
    test "removes a calibration that is not in use", %{conn: conn, config: config} do
      first = save(config, 580.8)
      save(config, 590.0)

      conn = delete(conn, "/api/saved-calibrations/#{first.id}")
      assert response(conn, 204) == ""
      assert Library.fetch(first.id) == {:error, :not_found}
    end

    test "returns the unit to its built-in calibration, then removes the calibration in use",
         %{conn: conn, config: config} do
      saved = save(config, 580.8)

      conn = delete(conn, "/api/saved-calibrations/#{saved.id}")

      assert response(conn, 204) == ""
      assert Library.fetch(saved.id) == {:error, :not_found}
      assert {:ok, %{source: :built_in}} = VisionCore.Calibration.in_use(config, "hq")
    end

    test "answers 409 for the calibration in use without a built-in calibration to return to",
         %{conn: conn, config: config, tmp_dir: tmp_dir} do
      saved = save(config, 580.8)
      File.rm!(Path.join(tmp_dir, "hq.yaml"))

      assert %{"errors" => [%{"status" => "409", "title" => "In use", "detail" => detail}]} =
               conn |> delete("/api/saved-calibrations/#{saved.id}") |> json_response(409)

      assert detail =~ "no built-in calibration to return to"
      assert {:ok, _saved} = Library.fetch(saved.id)
    end

    test "answers 409 for the calibration in use while a calibration session runs",
         %{conn: conn, config: config} do
      saved = save(config, 580.8)
      {:ok, board} = VisionCore.Calibration.Board.new(8, 6, 0.025)
      :ok = VisionCore.Calibration.Session.start("hq", board)

      assert %{"errors" => [%{"status" => "409", "title" => "Not deleted"}]} =
               conn |> delete("/api/saved-calibrations/#{saved.id}") |> json_response(409)

      assert {:ok, _saved} = Library.fetch(saved.id)
    end

    test "answers 500 when the unit cannot return to its built-in calibration, the one in use left",
         %{conn: conn, config: config, tmp_dir: tmp_dir} do
      saved = save(config, 580.8)
      store = Path.join(tmp_dir, "camera_store")
      File.chmod!(store, 0o500)
      on_exit(fn -> File.chmod(store, 0o700) end)

      assert %{"errors" => [%{"status" => "500", "detail" => "cannot remove " <> _reason}]} =
               conn |> delete("/api/saved-calibrations/#{saved.id}") |> json_response(500)

      assert {:ok, _saved} = Library.fetch(saved.id)
      assert {:ok, %{source: :stored}} = VisionCore.Calibration.in_use(config, "hq")
    end

    test "answers 404 for one not saved", %{conn: conn} do
      assert conn |> delete("/api/saved-calibrations/#{@unknown}") |> json_response(404)
    end
  end

  describe "PATCH /api/saved-calibrations/:id with inUse" do
    test "puts a saved calibration in use, answering once the unit has taken it",
         %{conn: conn, config: config} do
      first = save(config, 580.8)
      save(config, 590.0)
      id = first.id

      assert %{"data" => %{"id" => ^id, "attributes" => %{"inUse" => true}}} =
               conn |> put_in_use(id) |> json_response(200)

      assert Library.in_use("hq").id == first.id

      assert {:ok, %{cameras: [%{calibration: %{camera_matrix: [580.8 | _rest]}}]}} =
               VisionCore.Calibration.in_use(config, "hq")
    end

    test "puts a saved pose in use", %{conn: conn, config: config} do
      pose = VisionApiWeb.CalibrationCase.pose()
      :ok = VisionCore.Camera.Pose.commit(config, :hq, pose)
      # The recorder saves the pose in use when it takes the change: before the next commit.
      :sys.get_state(Recorder)
      :ok = VisionCore.Camera.Pose.commit(config, :hq, %{pose | translation: [-0.07, 0.0, 0.0]})
      :sys.get_state(Recorder)
      [_newest, first] = Library.list("hq-pose")

      assert %{"data" => %{"attributes" => %{"inUse" => true}}} =
               conn |> put_in_use(first.id) |> json_response(200)

      assert Library.in_use("hq-pose").id == first.id
      assert {:ok, %{pose: %{pose: ^pose}}} = VisionCore.Calibration.in_use(config, "hq-pose")
    end

    test "names and puts in use in one change", %{conn: conn, config: config} do
      first = save(config, 580.8)
      save(config, 590.0)

      assert %{"data" => %{"attributes" => %{"name" => "Workshop", "inUse" => true}}} =
               conn
               |> patch_saved(first.id, %{name: " Workshop ", inUse: true})
               |> json_response(200)

      assert %{name: "Workshop", in_use: true} = Library.in_use("hq")
    end

    test "changes nothing for a name refused with inUse", %{conn: conn, config: config} do
      first = save(config, 580.8)
      second = save(config, 590.0)

      assert %{"errors" => [%{"status" => "422", "title" => "Invalid name"}]} =
               conn |> patch_saved(first.id, %{name: "  ", inUse: true}) |> json_response(422)

      assert Library.in_use("hq").id == second.id
      assert {:ok, %{name: name}} = Library.fetch(first.id)
      assert name == first.name
    end

    test "answers the calibration as it is for the inUse it already has",
         %{conn: conn, config: config} do
      first = save(config, 580.8)
      second = save(config, 590.0)

      assert %{"data" => %{"attributes" => %{"inUse" => true}}} =
               conn |> patch_saved(second.id, %{inUse: true}) |> json_response(200)

      assert %{"data" => %{"attributes" => %{"inUse" => false}}} =
               conn |> patch_saved(first.id, %{inUse: false}) |> json_response(200)

      assert Library.in_use("hq").id == second.id
    end

    test "answers 422 for inUse false on the calibration in use, which a reset or another one ends",
         %{conn: conn, config: config} do
      saved = save(config, 580.8)

      assert %{
               "errors" => [
                 %{
                   "status" => "422",
                   "title" => "Still in use",
                   "source" => %{"pointer" => "/data/attributes/inUse"}
                 }
               ]
             } = conn |> patch_saved(saved.id, %{inUse: false}) |> json_response(422)

      assert Library.in_use("hq").id == saved.id
    end

    test "answers 400 for an inUse that is not a boolean, or without a name or inUse",
         %{conn: conn, config: config} do
      id = save(config, 580.8).id

      assert %{"errors" => [%{"source" => %{"pointer" => "/data/attributes/inUse"}}]} =
               conn |> patch_saved(id, %{inUse: "yes"}) |> json_response(400)

      assert %{"errors" => [%{"source" => %{"pointer" => "/data/attributes"}}]} =
               conn |> patch_saved(id, %{}) |> json_response(400)
    end

    test "answers 422 when the unit cannot take the files, changing nothing",
         %{conn: conn, config: config, tmp_dir: tmp_dir} do
      first = save(config, 580.8)
      second = save(config, 590.0)
      store = Path.join(tmp_dir, "camera_store")
      File.chmod!(store, 0o500)
      on_exit(fn -> File.chmod(store, 0o700) end)

      assert %{"errors" => [%{"status" => "422", "title" => "Not put in use"}]} =
               conn
               |> patch_saved(first.id, %{name: "Workshop", inUse: true})
               |> json_response(422)

      assert Library.in_use("hq").id == second.id
      assert {:ok, %{name: name}} = Library.fetch(first.id)
      assert name == first.name
    end

    @tag :capture_log
    test "answers 500 when the task putting it in use exits, the one in use left",
         %{conn: conn, config: config} do
      first = save(config, 580.8)
      second = save(config, 590.0)

      # Holds the camera's lock, so that the task waits for it until killed.
      lock = {{VisionCore.Camera.Calibration, :hq}, self()}
      true = :global.set_lock(lock, [node()])
      request = Task.async(fn -> put_in_use(conn, first.id) end)
      Process.exit(await_calibration_task(), :kill)
      answer = Task.await(request)
      :global.del_lock(lock, [node()])

      assert %{
               "errors" => [
                 %{
                   "status" => "500",
                   "detail" => "putting the calibration in use failed; the log says why"
                 }
               ]
             } = json_response(answer, 500)

      assert Library.in_use("hq").id == second.id
    end

    test "answers 404 for a calibration not saved", %{conn: conn} do
      for id <- [@unknown, "abc"] do
        assert %{"errors" => [%{"status" => "404"}]} =
                 conn |> put_in_use(id) |> json_response(404)
      end
    end

    test "answers 409 while a calibration session runs, and still takes a name",
         %{conn: conn, config: config} do
      first = save(config, 580.8)
      save(config, 590.0)
      {:ok, board} = VisionCore.Calibration.Board.new(8, 6, 0.025)
      :ok = VisionCore.Calibration.Session.start("hq", board)

      assert %{"errors" => [%{"status" => "409", "title" => "Not put in use"}]} =
               conn
               |> patch_saved(first.id, %{name: "Workshop", inUse: true})
               |> json_response(409)

      assert {:ok, %{name: name, in_use: false}} = Library.fetch(first.id)
      assert name == first.name

      assert %{"data" => %{"attributes" => %{"name" => "Workshop"}}} =
               conn |> patch_saved(first.id, %{name: "Workshop"}) |> json_response(200)
    end
  end

  test "a reset leaves no saved calibration in use", %{conn: conn, config: config} do
    save(config, 580.8)

    assert conn |> reset("hq") |> json_response(201)

    assert %{"data" => [%{"attributes" => %{"inUse" => false}}]} =
             conn |> get("/api/saved-calibrations") |> json_response(200)
  end

  describe "while the saved calibrations cannot be read" do
    setup %{config: config} do
      saved = save(config, 580.8)
      Repo.query!("ALTER TABLE camera_calibrations RENAME TO camera_calibrations_away")

      on_exit(fn ->
        Repo.query!("ALTER TABLE camera_calibrations_away RENAME TO camera_calibrations")
      end)

      %{id: saved.id}
    end

    defp assert_unavailable(conn) do
      assert %{
               "errors" => [
                 %{"status" => "503", "title" => "Saved calibrations unavailable"} = error
               ]
             } =
               json_response(conn, 503)

      refute Map.has_key?(error, "source")
    end

    test "GET and DELETE /api/saved-calibrations/:id answer 503", %{conn: conn, id: id} do
      conn |> get("/api/saved-calibrations/#{id}") |> assert_unavailable()
      conn |> delete("/api/saved-calibrations/#{id}") |> assert_unavailable()
    end

    test "PATCH /api/saved-calibrations/:id answers 503, not a fault of the name",
         %{conn: conn, id: id} do
      document = %{data: %{type: "saved-calibrations", id: id, attributes: %{name: "Workshop"}}}

      conn |> rename(id, document) |> assert_unavailable()
    end

    test "PATCH /api/saved-calibrations/:id with inUse answers 503", %{conn: conn, id: id} do
      conn |> put_in_use(id) |> assert_unavailable()
    end
  end

  test "another method on the routes answers 405 with the methods they take", %{conn: conn} do
    conn = put(conn, "/api/saved-calibrations/1")
    assert json_response(conn, 405)
    assert get_resp_header(conn, "allow") == ["GET, PATCH, DELETE"]
  end
end
