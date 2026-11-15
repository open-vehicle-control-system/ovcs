defmodule VisionApiWeb.DiskFormatControllerTest do
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
    TestDisks.plug(disks, "sdb1", TestDisks.blank_image())
    TestDisks.eventually(fn -> match?({:ok, %{state: :mounted}}, Disks.fetch(Disks, @stick)) end)
    TestDisks.eventually(fn -> length(Disks.list(Disks)) == 3 end)
    %{disks: disks}
  end

  defp format(conn, disk_id, attributes \\ %{label: "new-recordings"}) do
    post_document(conn, "/api/disk-formats", %{
      type: "disk-formats",
      attributes: attributes,
      relationships: %{disk: %{data: %{type: "disks", id: disk_id}}}
    })
  end

  test "formats a disk without a filesystem f2fs with the label, then it is mounted", %{
    conn: conn
  } do
    conn = format(conn, "sdb1")

    assert %{
             "data" => %{
               "type" => "disk-formats",
               "attributes" => %{"label" => "new-recordings"},
               "relationships" => %{"disk" => %{"data" => %{"type" => "disks", "id" => "sdb1"}}}
             }
           } = json_response(conn, 201)

    TestDisks.eventually(fn ->
      Enum.any?(Disks.list(Disks), &match?(%{label: "new-recordings", state: :mounted}, &1))
    end)
  end

  test "formats an ejected disk", %{conn: conn} do
    :ok = Disks.eject(Disks, @stick)

    assert %{"data" => %{"type" => "disk-formats"}} = conn |> format(@stick) |> json_response(201)
  end

  test "answers 409 for the unit's storage, a mounted disk and one unplugged", %{
    conn: conn,
    disks: disks
  } do
    for id <- ["internal", @stick] do
      assert %{"errors" => [%{"status" => "409"}]} = conn |> format(id) |> json_response(409)
    end

    File.rm_rf!(Path.join(disks[:block_devices_path], "sda"))

    TestDisks.eventually(fn ->
      match?({:ok, %{state: :unplugged}}, Disks.fetch(Disks, @stick))
    end)

    assert %{"errors" => [%{"status" => "409", "detail" => detail}]} =
             conn |> format(@stick) |> json_response(409)

    assert detail =~ "not plugged in"
  end

  test "answers 500 when mkfs.f2fs fails, saying why", %{conn: conn, tmp_dir: tmp_dir} do
    TestDisks.fail_mkfs(tmp_dir)

    assert %{"errors" => [%{"status" => "500", "detail" => detail}]} =
             conn |> format("sdb1") |> json_response(500)

    assert detail =~ "Failed to open"
  end

  test "answers 422 for a label f2fs cannot hold", %{conn: conn} do
    assert %{"errors" => [%{"status" => "422", "source" => source}]} =
             conn |> format("sdb1", %{label: String.duplicate("a", 513)}) |> json_response(422)

    assert source == %{"pointer" => "/data/attributes/label"}
  end

  test "answers 400 without a label of text", %{conn: conn} do
    for attributes <- [%{}, %{label: 3}, nil] do
      assert %{"errors" => [%{"status" => "400", "source" => source}]} =
               conn |> format("sdb1", attributes) |> json_response(400)

      assert source == %{"pointer" => "/data/attributes/label"}
    end
  end

  test "answers 404 for a disk the unit does not know, 400 without one", %{conn: conn} do
    assert %{"errors" => [%{"status" => "404"}]} = conn |> format("unknown") |> json_response(404)

    assert %{"errors" => [%{"status" => "400"}]} =
             conn
             |> post_document("/api/disk-formats", %{
               type: "disk-formats",
               attributes: %{label: "x"}
             })
             |> json_response(400)
  end

  test_document_refusals("/api/disk-formats", "disk-formats")
end
