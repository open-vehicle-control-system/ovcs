defmodule VisionApiWeb.CalibrationApplyControllerTest do
  use VisionApiWeb.CalibrationCase

  import VisionApiWeb.RefusalTests

  test_document_refusals("/api/calibration-applies", "calibration-applies")
  test_calibration_unit_refusals("/api/calibration-applies", "calibration-applies")

  alias VisionCore.Calibration.Session

  @media_type "application/vnd.api+json"

  defp solved(result \\ solved_result()) do
    :sys.replace_state(Session, &%{&1 | phase: :solved, result: result, samples: good_samples()})
  end

  describe "with a session capturing" do
    setup :capturing

    test "POST /api/calibration-applies answers 422 before a solve", %{conn: conn} do
      assert %{"errors" => [%{"status" => "422", "title" => "Not applied"}]} =
               conn
               |> post_document("/api/calibration-applies", %{type: "calibration-applies"})
               |> json_response(422)
    end

    test "POST /api/calibration-applies answers 202 with the session applying, and a cancel is a conflict",
         %{conn: conn} do
      solved()

      applied = post_document(conn, "/api/calibration-applies", %{type: "calibration-applies"})
      assert get_resp_header(applied, "content-type") == [@media_type]

      assert %{"data" => %{"attributes" => %{"phase" => "applying"}}} =
               json_response(applied, 202)

      assert_receive {:commit, commit}

      assert %{"errors" => [%{"status" => "409", "detail" => "the calibration is being applied"}]} =
               conn
               |> post_document("/api/calibration-cancels", %{type: "calibration-cancels"})
               |> json_response(409)

      send(commit, :go)
    end
  end

  test "a camera's solve gives its one calibration, and its apply commits it", %{conn: conn} do
    conn |> post_document("/api/calibration-sessions", session("hq")) |> json_response(201)
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
    |> post_document("/api/calibration-applies", %{type: "calibration-applies"})
    |> json_response(202)

    assert_receive {:commit_camera, :hq}
  end

  test "a pose's solve gives the pose, and its apply commits it", %{conn: conn} do
    conn |> post_document("/api/calibration-sessions", session("hq-pose")) |> json_response(201)
    solved(solved_pose_result())

    assert %{
             result: %{
               cameras: [],
               stereoRmsPx: nil,
               baselineM: nil,
               fxPx: nil,
               samples: 40,
               pose: %{
                 rotation: [0.999 | _],
                 translation: translation,
                 distanceMm: distance_mm,
                 rmsPx: 0.4,
                 file: "hq_pose.yaml",
                 yaml: yaml
               }
             }
           } = VisionApiWeb.CalibrationJSON.session(Session.state())

    assert translation == VisionApiWeb.CalibrationCase.pose().translation
    assert_in_delta distance_mm, 60.53, 0.01
    assert VisionCore.Camera.Pose.parse(yaml) == {:ok, VisionApiWeb.CalibrationCase.pose()}

    conn
    |> post_document("/api/calibration-applies", %{type: "calibration-applies"})
    |> json_response(202)

    assert_receive {:commit_pose, :hq}
  end
end
