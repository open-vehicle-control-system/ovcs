defmodule VisionApiWeb.CalibrationCancelControllerTest do
  use VisionApiWeb.CalibrationCase

  import VisionApiWeb.RefusalTests

  test_document_refusals("/api/calibration-cancels", "calibration-cancels")
  test_calibration_unit_refusals("/api/calibration-cancels", "calibration-cancels")

  test "POST /api/calibration-cancels ends the session", %{conn: conn} do
    post_document(conn, "/api/calibration-sessions", session())

    assert %{
             "data" => %{
               "type" => "calibration-cancels",
               "attributes" => %{"phase" => "idle"},
               "relationships" => %{"calibration" => %{"data" => nil}}
             }
           } =
             conn
             |> post_document("/api/calibration-cancels", %{type: "calibration-cancels"})
             |> json_response(201)
  end
end
