defmodule VisionApiWeb.CalibrationControllerTest do
  use VisionApiWeb.CalibrationCase

  test "GET /api/calibration renders the calibration in use", %{conn: conn} do
    conn = get(conn, "/api/calibration")
    assert get_resp_header(conn, "content-type") == ["application/vnd.api+json"]

    assert %{
             "data" => %{
               "type" => "calibrations",
               "id" => "unit",
               "attributes" => %{
                 "source" => "builtIn",
                 "storedAt" => nil,
                 "canReset" => false,
                 "prefix" => "unit",
                 "baselineM" => baseline_m,
                 "rectifiedFx" => 880.0,
                 "left" => %{
                   "imageWidth" => 1280,
                   "imageHeight" => 720,
                   "fx" => 900.0,
                   "fy" => 910.0,
                   "cx" => 640.0,
                   "cy" => 360.0,
                   "distortion" => [0.1, -0.2 | _],
                   "yaml" => "image_width: 1280" <> _
                 },
                 "right" => %{"fx" => 900.0}
               }
             }
           } = json_response(conn, 200)

    assert is_number(baseline_m) or baseline_m == nil
  end

  test "GET /api/calibration renders null sides for an uncalibrated unit",
       %{conn: conn, tmp_dir: tmp_dir} do
    File.rm!(Path.join(tmp_dir, "unit_left.yaml"))
    File.rm!(Path.join(tmp_dir, "unit_right.yaml"))

    assert %{
             "data" => %{
               "attributes" => %{
                 "source" => "none",
                 "baselineM" => nil,
                 "rectifiedFx" => nil,
                 "left" => %{"fx" => nil, "distortion" => nil, "yaml" => nil}
               }
             }
           } = conn |> get("/api/calibration") |> json_response(200)
  end

  test "GET /api/calibration answers 503 when the calibration cannot be read",
       %{conn: conn, tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "unit_left.yaml")
    File.rm!(path)
    File.mkdir!(path)

    assert %{"errors" => [%{"status" => "503", "detail" => detail}]} =
             conn |> get("/api/calibration") |> json_response(503)

    assert detail =~ "cannot read"
  end

  test "GET /api/calibration answers 404 on a unit without a :stereo component", %{conn: conn} do
    VisionApiWeb.TestUnit.start(%VisionCore.Config{})

    assert %{"errors" => [%{"status" => "404", "detail" => detail}]} =
             conn |> get("/api/calibration") |> json_response(404)

    assert detail =~ ":stereo"
  end
end
