defmodule VisionApiWeb.CalibrationSolveControllerTest do
  use VisionApiWeb.CalibrationCase

  import VisionApiWeb.RefusalTests

  test_document_refusals("/api/calibration-solves", "calibration-solves")
  test_calibration_unit_refusals("/api/calibration-solves", "calibration-solves")

  alias VisionCore.Calibration.Session

  defp solvable do
    :sys.replace_state(Session, &%{&1 | samples: good_samples(), size: {1280, 720}})
  end

  describe "with a session capturing" do
    setup :capturing

    test "POST /api/calibration-solves answers 422 before good enough", %{conn: conn} do
      assert %{"errors" => [%{"status" => "422", "title" => "Not solved"}]} =
               conn
               |> post_document("/api/calibration-solves", %{type: "calibration-solves"})
               |> json_response(422)
    end

    test "POST /api/calibration-solves answers 202 once the solve has begun, whose result carries the image size and each camera's YAML",
         %{conn: conn} do
      solvable()
      {:ok, _state} = Session.subscribe()

      assert %{"data" => %{"type" => "calibration-solves", "attributes" => %{"phase" => phase}}} =
               conn
               |> post_document("/api/calibration-solves", %{type: "calibration-solves"})
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
             } = VisionApiWeb.CalibrationSessionJSON.session(state)

      assert "image_width: 1280" <> _ = left_yaml
      assert left_yaml =~ "camera_name: unit_left"
      assert right_yaml =~ "camera_name: unit_right"
    end
  end
end
