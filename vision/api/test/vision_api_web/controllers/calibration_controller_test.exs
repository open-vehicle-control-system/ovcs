defmodule VisionApiWeb.CalibrationControllerTest do
  use VisionApiWeb.CalibrationCase

  test "GET /api/calibrations lists the stereo pair's calibration, then each camera's",
       %{conn: conn} do
    conn = get(conn, "/api/calibrations")
    assert get_resp_header(conn, "content-type") == ["application/vnd.api+json"]

    assert %{"data" => [stereo, camera]} = json_response(conn, 200)

    assert %{
             "type" => "calibrations",
             "id" => "unit",
             "attributes" => %{"kind" => "stereo", "cameras" => [%{"name" => "left"}, _right]}
           } = stereo

    assert %{
             "type" => "calibrations",
             "id" => "hq",
             "attributes" => %{
               "kind" => "camera",
               "source" => "builtIn",
               "baselineM" => nil,
               "rectifiedFx" => nil,
               "cameras" => [%{"name" => "hq", "file" => "hq.yaml", "fx" => 900.0}]
             }
           } = camera
  end

  test "GET /api/calibrations is empty on a unit with nothing to calibrate", %{conn: conn} do
    VisionApiWeb.TestUnit.start(%VisionCore.Config{})

    assert conn |> get("/api/calibrations") |> json_response(200) == %{"data" => []}
  end

  test "GET /api/calibrations/:id renders the stereo pair's calibration in use", %{conn: conn} do
    conn = get(conn, "/api/calibrations/unit")
    assert get_resp_header(conn, "content-type") == ["application/vnd.api+json"]

    assert %{
             "data" => %{
               "type" => "calibrations",
               "id" => "unit",
               "attributes" => %{
                 "kind" => "stereo",
                 "source" => "builtIn",
                 "storedAt" => nil,
                 "canReset" => false,
                 "error" => nil,
                 "baselineM" => baseline_m,
                 "rectifiedFx" => 880.0,
                 "cameras" => [
                   %{
                     "name" => "left",
                     "file" => "unit_left.yaml",
                     "imageWidth" => 1280,
                     "imageHeight" => 720,
                     "fx" => 900.0,
                     "fy" => 910.0,
                     "cx" => 640.0,
                     "cy" => 360.0,
                     "distortion" => [0.1, -0.2 | _],
                     "yaml" => "image_width: 1280" <> _
                   },
                   %{"name" => "right", "file" => "unit_right.yaml", "fx" => 900.0}
                 ]
               }
             }
           } = json_response(conn, 200)

    assert is_number(baseline_m) or baseline_m == nil
  end

  test "GET /api/calibrations/:id renders null cameras for an uncalibrated unit",
       %{conn: conn, tmp_dir: tmp_dir} do
    File.rm!(Path.join(tmp_dir, "unit_left.yaml"))
    File.rm!(Path.join(tmp_dir, "unit_right.yaml"))

    assert %{
             "data" => %{
               "attributes" => %{
                 "source" => "none",
                 "baselineM" => nil,
                 "rectifiedFx" => nil,
                 "cameras" => [%{"fx" => nil, "distortion" => nil, "yaml" => nil}, _right]
               }
             }
           } = conn |> get("/api/calibrations/unit") |> json_response(200)
  end

  @tag :capture_log
  test "a calibration whose file cannot be read is listed and shown with why, its cameras without figures",
       %{conn: conn, tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "unit_left.yaml")
    File.rm!(path)
    File.mkdir!(path)

    assert %{"data" => %{"attributes" => attributes}} =
             conn |> get("/api/calibrations/unit") |> json_response(200)

    assert attributes["error"] =~ "cannot read"

    assert [%{"name" => "left", "fx" => nil, "yaml" => nil}, %{"fx" => 900.0}] =
             attributes["cameras"]

    assert attributes["baselineM"] == nil
    assert attributes["rectifiedFx"] == nil

    assert %{"data" => [%{"id" => "unit", "attributes" => %{"error" => error}}, %{"id" => "hq"}]} =
             conn |> get("/api/calibrations") |> json_response(200)

    assert error =~ "cannot read"
  end

  @tag :capture_log
  test "a calibration file whose matrices are malformed gives an error, not a crash",
       %{conn: conn, tmp_dir: tmp_dir} do
    File.write!(Path.join(tmp_dir, "hq.yaml"), "camera_matrix:\n  data: [1, 2]\n")

    assert %{"data" => %{"attributes" => %{"error" => error, "cameras" => [%{"fx" => nil}]}}} =
             conn |> get("/api/calibrations/hq") |> json_response(200)

    assert error =~ "camera matrix has 2 values"
  end

  test "GET /api/calibrations/:id answers 404 for an id that is none of the unit's targets",
       %{conn: conn} do
    conn = get(conn, "/api/calibrations/rear")
    assert get_resp_header(conn, "content-type") == ["application/vnd.api+json"]

    assert %{"errors" => [%{"status" => "404", "detail" => "no calibration rear"}]} =
             json_response(conn, 404)
  end
end
