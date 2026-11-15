defmodule VisionApiWeb.DiskEjectControllerTest do
  use VisionApiWeb.ConnCase, async: false

  import VisionApiWeb.RefusalTests

  alias VisionApiWeb.TestDisks
  alias VisionCore.Disks

  @moduletag :tmp_dir
  @moduletag :capture_log

  @stick "c8803634-2bd4-4a62-8a68-ad456f6a52ce"

  setup %{tmp_dir: tmp_dir} do
    disks = TestDisks.start_unit(tmp_dir)
    TestDisks.plug(disks, "sda1", TestDisks.f2fs_image(@stick, "ovcs-recordings"))
    TestDisks.eventually(fn -> match?({:ok, %{state: :mounted}}, Disks.fetch(Disks, @stick)) end)
    :ok
  end

  defp eject(conn, disk_id) do
    post_document(conn, "/api/disk-ejects", %{
      type: "disk-ejects",
      relationships: %{disk: %{data: %{type: "disks", id: disk_id}}}
    })
  end

  test "ejects a disk, unmounted once it answers", %{conn: conn} do
    conn = eject(conn, @stick)

    assert %{
             "data" => %{
               "type" => "disk-ejects",
               "id" => _id,
               "relationships" => %{"disk" => %{"data" => %{"type" => "disks", "id" => @stick}}}
             }
           } = json_response(conn, 201)

    assert {:ok, %{state: :ejected}} = Disks.fetch(Disks, @stick)
  end

  test "answers 409 for the unit's storage and a disk not mounted", %{conn: conn} do
    :ok = Disks.eject(Disks, @stick)

    for id <- ["internal", @stick] do
      assert %{"errors" => [%{"status" => "409", "source" => source}]} =
               conn |> eject(id) |> json_response(409)

      assert source == %{"pointer" => "/data/relationships/disk"}
    end
  end

  test "answers 409 for a disk that stays busy, mounted still", %{tmp_dir: tmp_dir} do
    dir = Path.join(tmp_dir, "busy")
    disks = TestDisks.start_unit(dir, eject_timeout_ms: 50)
    TestDisks.plug(disks, "sda1", TestDisks.f2fs_image(@stick, "ovcs-recordings"))
    TestDisks.eventually(fn -> match?({:ok, %{state: :mounted}}, Disks.fetch(Disks, @stick)) end)
    TestDisks.hold_busy(dir, true)

    assert %{"errors" => [%{"status" => "409", "detail" => detail}]} =
             build_conn() |> eject(@stick) |> json_response(409)

    assert detail =~ "busy"
    assert {:ok, %{state: :mounted}} = Disks.fetch(Disks, @stick)
  end

  test "answers 404 for a disk the unit does not know", %{conn: conn} do
    assert %{"errors" => [%{"status" => "404", "source" => source}]} =
             conn |> eject("unknown") |> json_response(404)

    assert source == %{"pointer" => "/data/relationships/disk"}
  end

  test "answers 400 without a disk relationship", %{conn: conn} do
    for relationships <- [nil, %{}, %{disk: %{data: %{type: "recordings", id: @stick}}}] do
      assert %{"errors" => [%{"status" => "400", "source" => source}]} =
               conn
               |> post_document("/api/disk-ejects", %{
                 type: "disk-ejects",
                 relationships: relationships
               })
               |> json_response(400)

      assert source == %{"pointer" => "/data/relationships/disk"}
    end
  end

  test_document_refusals("/api/disk-ejects", "disk-ejects")
end
