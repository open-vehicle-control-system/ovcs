defmodule VisionApiWeb.CalibrationResetControllerTest do
  use VisionApiWeb.CalibrationCase

  import VisionApiWeb.RefusalTests

  test_document_refusals("/api/calibration-resets", "calibration-resets")
  test_calibration_unit_refusals("/api/calibration-resets", "calibration-resets")

  @media_type "application/vnd.api+json"

  describe "POST /api/calibration-resets" do
    defp reset(id), do: %{type: "calibration-resets", relationships: target(id)}

    defp await_reset_task do
      case Task.Supervisor.children(VisionCore.Calibration.Tasks) do
        [task] ->
          task

        [] ->
          receive do
          after
            5 -> await_reset_task()
          end
      end
    end

    test "returns a camera's pose to its built-in one", %{
      conn: conn,
      config: config,
      tmp_dir: tmp_dir
    } do
      alias VisionCore.Camera.Pose

      built_in = VisionApiWeb.CalibrationCase.pose()
      File.write!(Path.join(tmp_dir, "hq_pose.yaml"), Pose.to_yaml(built_in))
      :ok = Pose.commit(config, :hq, %{built_in | translation: [-0.07, 0.0, 0.0]})

      assert %{"data" => %{"attributes" => %{"source" => "stored", "canReset" => true}}} =
               conn |> get("/api/calibrations/hq-pose") |> json_response(200)

      conn |> post_document("/api/calibration-resets", reset("hq-pose")) |> json_response(201)

      assert %{"data" => %{"attributes" => %{"source" => "builtIn", "pose" => pose}}} =
               conn |> get("/api/calibrations/hq-pose") |> json_response(200)

      assert pose["translation"] == [-0.06, 0.008, 0.0]
    end

    test "answers 422 for a stored pose without a built-in one to return to",
         %{conn: conn, config: config} do
      :ok = VisionCore.Camera.Pose.commit(config, :hq, VisionApiWeb.CalibrationCase.pose())

      assert %{
               "errors" => [
                 %{"status" => "422", "detail" => "there is no built-in pose to return to"}
               ]
             } =
               conn
               |> post_document("/api/calibration-resets", reset("hq-pose"))
               |> json_response(422)
    end

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
               conn
               |> post_document("/api/calibration-resets", reset("unit"))
               |> json_response(201)

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

      conn |> post_document("/api/calibration-resets", reset("hq")) |> json_response(201)

      assert %{"data" => %{"attributes" => %{"source" => "builtIn"}}} =
               conn |> get("/api/calibrations/hq") |> json_response(200)
    end

    test "answers 409 while a calibration session runs, and resets nothing",
         %{conn: conn, config: config} do
      :ok =
        VisionCore.Camera.Calibration.commit(
          config,
          :hq,
          %{VisionApiWeb.CalibrationCase.calibration() | width: 640}
        )

      {:ok, board} = VisionCore.Calibration.Board.new(8, 6, 0.025)
      :ok = VisionCore.Calibration.Session.start("unit", board)

      assert %{
               "errors" => [
                 %{
                   "status" => "409",
                   "title" => "Not reset",
                   "detail" => "a calibration session is running"
                 }
               ]
             } =
               conn |> post_document("/api/calibration-resets", reset("hq")) |> json_response(409)

      assert %{"data" => %{"attributes" => %{"source" => "stored"}}} =
               conn |> get("/api/calibrations/hq") |> json_response(200)
    end

    test "answers 422 when nothing is stored", %{conn: conn} do
      for id <- ["unit", "hq"] do
        assert %{"errors" => [%{"status" => "422", "title" => "Not reset"}]} =
                 conn |> post_document("/api/calibration-resets", reset(id)) |> json_response(422)
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
               conn |> post_document("/api/calibration-resets", reset("hq")) |> json_response(422)

      assert detail =~ "no built-in calibration"
    end

    @tag :capture_log
    test "answers 500 when the unit does not take the built-in calibration, the stored one left in place",
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

      reset = post_document(conn, "/api/calibration-resets", reset("unit"))
      assert get_resp_header(reset, "content-type") == [@media_type]
      assert %{"errors" => [%{"status" => "500", "detail" => detail}]} = json_response(reset, 500)
      assert detail =~ "does_not_fit"
      assert File.read!(cameras[:left][:calibration_store_path]) == "stored left"
    end

    @tag :capture_log
    test "answers 500 when the reset's task exits, the stored calibration left in place",
         %{conn: conn, config: config} do
      :ok =
        VisionCore.Camera.Calibration.commit(
          config,
          :hq,
          %{VisionApiWeb.CalibrationCase.calibration() | width: 640}
        )

      # Holds the camera's lock, so that the reset's task waits for it until killed.
      lock = {{VisionCore.Camera.Calibration, :hq}, self()}
      true = :global.set_lock(lock, [node()])
      request = Task.async(fn -> post_document(conn, "/api/calibration-resets", reset("hq")) end)
      Process.exit(await_reset_task(), :kill)
      reset = Task.await(request)
      :global.del_lock(lock, [node()])

      assert get_resp_header(reset, "content-type") == [@media_type]

      assert %{
               "errors" => [
                 %{"status" => "500", "detail" => "the reset failed; the log says why"}
               ]
             } = json_response(reset, 500)

      assert %{"data" => %{"attributes" => %{"source" => "stored"}}} =
               conn |> get("/api/calibrations/hq") |> json_response(200)
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
               |> post_document("/api/calibration-resets", %{type: "calibration-resets"})
               |> json_response(400)

      assert %{"errors" => [%{"status" => "404"}]} =
               conn
               |> post_document("/api/calibration-resets", reset("rear"))
               |> json_response(404)
    end
  end
end
