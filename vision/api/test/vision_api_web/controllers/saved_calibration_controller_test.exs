defmodule VisionApiWeb.SavedCalibrationControllerTest do
  use VisionApiWeb.CalibrationCase

  alias VisionCore.Calibration.{Library, Recorder, Saved, Selection}
  alias VisionCore.Camera.Calibration, as: OwnCalibration
  alias VisionCore.Repo
  alias VisionCore.Ros2.CameraCalibration

  setup %{config: config} do
    Repo.delete_all(Selection)
    Repo.delete_all(Saved)
    start_supervised!({Recorder, config: config})
    :ok
  end

  defp calibration(fx) do
    built_in = VisionApiWeb.CalibrationCase.calibration()
    [_fx | rest] = built_in.camera_matrix
    %{built_in | camera_matrix: [fx | rest]}
  end

  # Commits a calibration of the camera `hq`, which the recorder keeps and selects.
  defp keep(config, fx, kept \\ nil) do
    if kept, do: Recorder.expect("hq", [{"hq", calibration(fx)}], {:record, kept})
    :ok = OwnCalibration.commit(config, :hq, calibration(fx))
    :sys.get_state(Recorder)
    hd(Library.list("hq"))
  end

  defp jsonapi(conn),
    do: put_req_header(conn, "content-type", "application/vnd.api+json")

  defp rename(conn, id, document),
    do: conn |> jsonapi() |> patch("/api/saved-calibrations/#{id}", Jason.encode!(document))

  defp select(conn, document),
    do: conn |> jsonapi() |> post("/api/calibration-selections", Jason.encode!(document))

  defp selection(id),
    do: %{
      data: %{
        type: "calibration-selections",
        relationships: %{savedCalibration: %{data: %{type: "saved-calibrations", id: id}}}
      }
    }

  describe "GET /api/saved-calibrations" do
    test "lists the calibrations kept for every target, the newest first, with the one in force",
         %{conn: conn, config: config} do
      first = keep(config, 580.8)

      second =
        keep(config, 590.0,
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
                 "inForce" => true,
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

      assert id == Integer.to_string(second.id)
      assert name == second.name
      assert distortion == [0.1, -0.2, 0.0, 0.0, 0.0]
      assert yaml == CameraCalibration.to_yaml(calibration(590.0), "hq")
      assert {:ok, _time, 0} = DateTime.from_iso8601(created_at)

      assert %{
               "id" => oldest_id,
               "attributes" => %{"origin" => "imported", "inForce" => false, "board" => nil}
             } =
               oldest

      assert oldest_id == Integer.to_string(first.id)
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

    test "lists one target's with filter[calibration], and none for a target without any",
         %{conn: conn, config: config} do
      keep(config, 580.8)

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
    test "renders one calibration kept", %{conn: conn, config: config} do
      saved = keep(config, 580.8)

      assert %{"data" => %{"id" => id, "attributes" => %{"inForce" => true}}} =
               conn |> get("/api/saved-calibrations/#{saved.id}") |> json_response(200)

      assert id == Integer.to_string(saved.id)
    end

    test "answers 404 for one the unit does not keep, or an id that is no number", %{conn: conn} do
      for id <- ["999999", "abc", "1x"] do
        assert %{"errors" => [%{"status" => "404", "detail" => detail}]} =
                 conn |> get("/api/saved-calibrations/#{id}") |> json_response(404)

        assert detail == "no saved calibration #{id}"
      end
    end

    test "answers 404 for an id written another way than the unit writes it",
         %{conn: conn, config: config} do
      id = keep(config, 580.8).id

      for other <- ["0#{id}", "+#{id}", "-#{id}", "0", "99999999999999999999999999"] do
        assert conn |> get("/api/saved-calibrations/#{other}") |> json_response(404)
        assert conn |> delete("/api/saved-calibrations/#{other}") |> json_response(404)

        document = %{data: %{type: "saved-calibrations", id: other, attributes: %{name: "x"}}}
        assert conn |> rename(other, document) |> json_response(404)

        assert conn |> select(selection(other)) |> json_response(404)
      end

      assert {:ok, _saved} = Library.fetch(id)
    end
  end

  describe "PATCH /api/saved-calibrations/:id" do
    test "names a calibration", %{conn: conn, config: config} do
      saved = keep(config, 580.8)
      id = Integer.to_string(saved.id)

      document = %{data: %{type: "saved-calibrations", id: id, attributes: %{name: " Workshop "}}}

      assert %{"data" => %{"id" => ^id, "attributes" => %{"name" => "Workshop"}}} =
               conn |> rename(id, document) |> json_response(200)

      assert {:ok, %{name: "Workshop"}} = Library.fetch(saved.id)
    end

    test "answers 422 for a name that is empty or too long", %{conn: conn, config: config} do
      id = Integer.to_string(keep(config, 580.8).id)

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

    test "answers 400 without a name, 409 for another type or id, 404 for one not kept",
         %{conn: conn, config: config} do
      id = Integer.to_string(keep(config, 580.8).id)

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
             |> rename("999999", %{
               data: %{type: "saved-calibrations", id: "999999", attributes: %{name: "x"}}
             })
             |> json_response(404)
    end

    test "answers 400 for a form body", %{conn: conn, config: config} do
      id = keep(config, 580.8).id

      conn =
        conn
        |> put_req_header("content-type", "application/x-www-form-urlencoded")
        |> patch("/api/saved-calibrations/#{id}", "data[type]=saved-calibrations")

      assert json_response(conn, 400)
    end
  end

  describe "DELETE /api/saved-calibrations/:id" do
    test "removes a calibration that is not in force", %{conn: conn, config: config} do
      first = keep(config, 580.8)
      keep(config, 590.0)

      conn = delete(conn, "/api/saved-calibrations/#{first.id}")
      assert response(conn, 204) == ""
      assert Library.fetch(first.id) == {:error, :not_found}
    end

    test "returns the unit to its built-in calibration, then removes the calibration in force",
         %{conn: conn, config: config} do
      saved = keep(config, 580.8)

      conn = delete(conn, "/api/saved-calibrations/#{saved.id}")

      assert response(conn, 204) == ""
      assert Library.fetch(saved.id) == {:error, :not_found}
      assert {:ok, %{source: :built_in}} = VisionCore.Calibration.in_use(config, "hq")
    end

    test "answers 409 for the calibration in force without a built-in calibration to return to",
         %{conn: conn, config: config, tmp_dir: tmp_dir} do
      saved = keep(config, 580.8)
      File.rm!(Path.join(tmp_dir, "hq.yaml"))

      assert %{"errors" => [%{"status" => "409", "title" => "In force", "detail" => detail}]} =
               conn |> delete("/api/saved-calibrations/#{saved.id}") |> json_response(409)

      assert detail =~ "no built-in calibration to return to"
      assert {:ok, _saved} = Library.fetch(saved.id)
    end

    test "answers 409 for the calibration in force while a calibration session runs",
         %{conn: conn, config: config} do
      saved = keep(config, 580.8)
      {:ok, board} = VisionCore.Calibration.Board.new(8, 6, 0.025)
      :ok = VisionCore.Calibration.Session.start("hq", board)

      assert %{"errors" => [%{"status" => "409", "title" => "Not deleted"}]} =
               conn |> delete("/api/saved-calibrations/#{saved.id}") |> json_response(409)

      assert {:ok, _saved} = Library.fetch(saved.id)
    end

    test "answers 500 when the unit cannot return to its built-in calibration, keeping the one in force",
         %{conn: conn, config: config, tmp_dir: tmp_dir} do
      saved = keep(config, 580.8)
      store = Path.join(tmp_dir, "camera_store")
      File.chmod!(store, 0o500)
      on_exit(fn -> File.chmod(store, 0o700) end)

      assert %{"errors" => [%{"status" => "500", "detail" => "cannot remove " <> _reason}]} =
               conn |> delete("/api/saved-calibrations/#{saved.id}") |> json_response(500)

      assert {:ok, _saved} = Library.fetch(saved.id)
      assert {:ok, %{source: :stored}} = VisionCore.Calibration.in_use(config, "hq")
    end

    test "answers 404 for one not kept", %{conn: conn} do
      assert conn |> delete("/api/saved-calibrations/999999") |> json_response(404)
    end
  end

  describe "POST /api/calibration-selections" do
    test "puts a calibration kept back in force", %{conn: conn, config: config} do
      first = keep(config, 580.8)
      keep(config, 590.0)
      id = Integer.to_string(first.id)

      conn = select(conn, selection(id))

      assert %{
               "data" => %{
                 "type" => "calibration-selections",
                 "id" => action_id,
                 "relationships" => %{
                   "savedCalibration" => %{
                     "data" => %{"type" => "saved-calibrations", "id" => ^id}
                   }
                 }
               }
             } = json_response(conn, 201)

      assert is_binary(action_id)
      :sys.get_state(Recorder)
      assert Library.selected("hq").id == first.id

      assert {:ok, %{cameras: [%{calibration: %{camera_matrix: [580.8 | _rest]}}]}} =
               VisionCore.Calibration.in_use(config, "hq")
    end

    test "answers 404 for a calibration the unit does not keep", %{conn: conn} do
      for id <- ["999999", "abc"] do
        assert %{
                 "errors" => [
                   %{
                     "status" => "404",
                     "source" => %{"pointer" => "/data/relationships/savedCalibration"}
                   }
                 ]
               } = conn |> select(selection(id)) |> json_response(404)
      end
    end

    test "answers 409 while a calibration session runs", %{conn: conn, config: config} do
      saved = keep(config, 580.8)
      {:ok, board} = VisionCore.Calibration.Board.new(8, 6, 0.025)
      :ok = VisionCore.Calibration.Session.start("hq", board)

      assert %{"errors" => [%{"status" => "409", "title" => "Not selected"}]} =
               conn |> select(selection(Integer.to_string(saved.id))) |> json_response(409)
    end

    test "answers 400 without the relationship, 409 for another type, 403 for a client id",
         %{conn: conn} do
      assert conn |> select(%{data: %{type: "calibration-selections"}}) |> json_response(400)
      assert conn |> select(%{data: %{type: "calibrations"}}) |> json_response(409)
      assert conn |> select(%{}) |> json_response(400)

      document = put_in(selection("1"), [:data, :id], "7")
      assert conn |> select(document) |> json_response(403)
    end
  end

  describe "while the saved calibrations cannot be read" do
    setup %{config: config} do
      saved = keep(config, 580.8)
      Repo.query!("ALTER TABLE calibrations RENAME TO calibrations_away")
      on_exit(fn -> Repo.query!("ALTER TABLE calibrations_away RENAME TO calibrations") end)
      %{id: Integer.to_string(saved.id)}
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

    test "POST /api/calibration-selections answers 503", %{conn: conn, id: id} do
      conn |> select(selection(id)) |> assert_unavailable()
    end
  end

  test "another method on the routes answers 405 with the methods they take", %{conn: conn} do
    conn = put(conn, "/api/saved-calibrations/1")
    assert json_response(conn, 405)
    assert get_resp_header(conn, "allow") == ["GET, PATCH, DELETE"]
  end
end
