defmodule VisionApiWeb.DiskControllerTest do
  use VisionApiWeb.ConnCase, async: false

  import VisionApiWeb.RefusalTests

  alias VisionApiWeb.TestDisks
  alias VisionCore.Disks

  @moduletag :tmp_dir
  @moduletag :capture_log

  @media_type "application/vnd.api+json"
  @stick "c8803634-2bd4-4a62-8a68-ad456f6a52ce"

  setup %{tmp_dir: tmp_dir} do
    disks = TestDisks.start_unit(tmp_dir)
    TestDisks.plug(disks, "sda1", TestDisks.f2fs_image(@stick, "ovcs-recordings"))
    TestDisks.plug(disks, "sdb1", TestDisks.blank_image())
    TestDisks.eventually(fn -> match?({:ok, %{state: :mounted}}, Disks.fetch(Disks, @stick)) end)
    TestDisks.eventually(fn -> length(Disks.list(Disks)) == 3 end)
    :ok
  end

  defp change(conn, id, attributes) do
    document = %{data: %{type: "disks", id: id, attributes: attributes}}

    conn
    |> put_req_header("content-type", @media_type)
    |> patch("/api/disks/#{id}", Jason.encode!(document))
  end

  describe "GET /api/disks" do
    test "lists the disks in their order, then the unusable ones", %{conn: conn} do
      conn = get(conn, "/api/disks")
      assert get_resp_header(conn, "content-type") == [@media_type]
      assert %{"data" => [internal, stick, blank]} = json_response(conn, 200)

      assert %{
               "type" => "disks",
               "id" => "internal",
               "attributes" => %{
                 "internal" => true,
                 "state" => "mounted",
                 "position" => 0,
                 "enabled" => true,
                 "freeBytes" => 10_240_000_000
               }
             } = internal

      assert %{
               "id" => @stick,
               "attributes" => %{
                 "internal" => false,
                 "label" => "ovcs-recordings",
                 "filesystem" => "f2fs",
                 "device" => "sda1",
                 "sizeBytes" => 64_000_000_000,
                 "freeBytes" => 10_240_000_000,
                 "position" => 1,
                 "enabled" => true,
                 "state" => "mounted",
                 "problem" => nil,
                 "lastSeenAt" => last_seen_at
               }
             } = stick

      assert {:ok, _time, 0} = DateTime.from_iso8601(last_seen_at)

      assert %{
               "id" => "sdb1",
               "attributes" => %{
                 "state" => "unusable",
                 "device" => "sdb1",
                 "position" => nil,
                 "filesystem" => nil,
                 "problem" => "no f2fs or ext4 filesystem"
               }
             } = blank
    end

    test "is empty on a unit without a bag exporter", %{conn: conn} do
      VisionApiWeb.TestUnit.start(%VisionCore.Config{})

      assert %{"data" => []} = conn |> get("/api/disks") |> json_response(200)
    end
  end

  describe "PATCH /api/disks/:id" do
    test "moves a disk to a position in the order", %{conn: conn} do
      assert %{"data" => %{"id" => @stick, "attributes" => %{"position" => 0}}} =
               conn |> change(@stick, %{position: 0}) |> json_response(200)

      assert Enum.map(Disks.list(Disks), & &1.uuid) == [@stick, "internal", nil]
    end

    test "turns a disk off and on", %{conn: conn} do
      assert %{"data" => %{"attributes" => %{"enabled" => false}}} =
               conn |> change("internal", %{enabled: false}) |> json_response(200)

      assert %{"data" => %{"attributes" => %{"enabled" => true, "position" => 1}}} =
               build_conn()
               |> change("internal", %{enabled: true, position: 1})
               |> json_response(200)
    end

    test "answers 400 without a position or enabled of their kind", %{conn: conn} do
      for {attributes, pointer} <- [
            {%{}, "/data/attributes"},
            {nil, "/data/attributes"},
            {%{position: "first"}, "/data/attributes/position"},
            {%{position: -1}, "/data/attributes/position"},
            {%{position: 1.5}, "/data/attributes/position"},
            {%{enabled: "yes"}, "/data/attributes/enabled"}
          ] do
        assert %{"errors" => [%{"status" => "400", "source" => %{"pointer" => ^pointer}}]} =
                 conn |> change(@stick, attributes) |> json_response(400)
      end
    end

    test "answers 422 for a position past the last", %{conn: conn} do
      assert %{"errors" => [%{"status" => "422", "source" => %{"pointer" => pointer}}]} =
               conn |> change(@stick, %{position: 2}) |> json_response(422)

      assert pointer == "/data/attributes/position"
    end

    test "changes nothing when it refuses a part of the change", %{conn: conn} do
      assert %{"errors" => [%{"status" => "422"}]} =
               conn |> change("internal", %{enabled: false, position: 9}) |> json_response(422)

      assert {:ok, %{enabled: true, position: 0}} = Disks.fetch(Disks, "internal")
    end

    test "answers 409 for a disk without a filesystem, which has no place in the order", %{
      conn: conn
    } do
      assert %{"errors" => [%{"status" => "409"}]} =
               conn |> change("sdb1", %{enabled: false}) |> json_response(409)
    end

    test "answers 404 for a disk the unit does not know", %{conn: conn} do
      assert %{"errors" => [%{"status" => "404", "detail" => detail}]} =
               conn |> change("unknown", %{enabled: false}) |> json_response(404)

      assert detail =~ "no disk unknown"
    end

    test_change_refusals("/api/disks/internal", "disks", "internal")
  end

  describe "PATCH /api/disks/:id without the database" do
    setup %{tmp_dir: tmp_dir} do
      TestDisks.start_unit(Path.join(tmp_dir, "no_database"), repo: spawn(fn -> :ok end))
      :ok
    end

    test "answers 503, the order unsaved", %{conn: conn} do
      assert %{"errors" => [%{"status" => "503", "detail" => detail}]} =
               conn |> change("internal", %{enabled: false}) |> json_response(503)

      assert detail =~ "unavailable"
    end
  end
end
