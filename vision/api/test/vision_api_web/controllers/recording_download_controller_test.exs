defmodule VisionApiWeb.RecordingDownloadControllerTest do
  use VisionApiWeb.ConnCase, async: false

  alias VisionApiWeb.{AnsweringBag, TestDisks}

  @moduletag :tmp_dir
  @moduletag :capture_log

  @recording "20261115T090000Z_review"

  setup %{tmp_dir: tmp_dir} do
    disks = TestDisks.start_unit(tmp_dir)

    folders =
      for folder <- [@recording, @recording <> "_part2"] do
        dir = Path.join(disks[:internal], folder)
        File.mkdir_p!(dir)
        File.write!(Path.join(dir, "metadata.yaml"), "rosbag2_bagfile_information: ~")
        File.write!(Path.join(dir, "#{folder}_0.mcap"), :crypto.strong_rand_bytes(3_000))
        dir
      end

    %{folders: folders}
  end

  test "answers the recording as one tar, each part a folder of its files", %{
    conn: conn,
    folders: folders
  } do
    conn = get(conn, "/api/recordings/#{@recording}/download")

    tar = response(conn, 200)
    assert get_resp_header(conn, "content-type") == ["application/x-tar"]

    assert get_resp_header(conn, "content-disposition") == [
             ~s(attachment; filename="#{@recording}.tar")
           ]

    assert get_resp_header(conn, "content-length") == [Integer.to_string(byte_size(tar))]
    assert {:ok, files} = :erl_tar.extract({:binary, tar}, [:memory])

    expected =
      for dir <- folders,
          file <- File.ls!(dir),
          do: {~c"#{Path.basename(dir)}/#{file}", File.read!(Path.join(dir, file))}

    assert Enum.sort(files) == Enum.sort(expected)
  end

  test "answers the tar to a browser following a link", %{conn: conn} do
    conn =
      conn
      |> put_req_header(
        "accept",
        "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8"
      )
      |> get("/api/recordings/#{@recording}/download")

    assert {:ok, _files} = :erl_tar.extract({:binary, response(conn, 200)}, [:memory])
    assert get_resp_header(conn, "content-type") == ["application/x-tar"]
  end

  test "answers 500 before any byte for a recording whose names a tar cannot hold", %{
    conn: conn,
    folders: [folder | _parts]
  } do
    name = String.duplicate("r", 100)
    long = Path.join(Path.dirname(folder), name)
    File.mkdir_p!(long)
    File.write!(Path.join(long, "bag_0.mcap"), "cut")

    conn = get(conn, "/api/recordings/#{name}/download")

    assert get_resp_header(conn, "content-type") == ["application/vnd.api+json"]
    assert %{"errors" => [%{"status" => "500", "detail" => detail}]} = json_response(conn, 500)
    assert detail =~ "too long"
  end

  test "answers 504 when the bag exporter does not answer in time, 500 when it fails", %{
    conn: conn
  } do
    for {answer, status} <- [
          {{:error, :timeout}, 504},
          {{:error, {:failed, "crashed"}}, 500},
          {{:error, :unknown_call}, 500}
        ] do
      AnsweringBag.answer(answer)
      conn = get(conn, "/api/recordings/#{@recording}/download")

      assert get_resp_header(conn, "content-type") == ["application/vnd.api+json"]
      assert %{"errors" => [%{"status" => status_text}]} = json_response(conn, status)
      assert status_text == Integer.to_string(status)
    end
  end

  test "answers 404 for a name no recording has", %{conn: conn} do
    conn = get(conn, "/api/recordings/20261115T000000Z_review/download")

    assert get_resp_header(conn, "content-type") == ["application/vnd.api+json"]
    assert %{"errors" => [%{"status" => "404"}]} = json_response(conn, 404)
  end

  test "answers 409 while it records, its files still growing", %{conn: conn} do
    %{"data" => %{"id" => id}} =
      conn
      |> post_document("/api/recordings", %{type: "recordings"})
      |> json_response(201)

    assert %{"errors" => [%{"status" => "409", "detail" => detail}]} =
             build_conn() |> get("/api/recordings/#{id}/download") |> json_response(409)

    assert detail =~ "stop it first"

    build_conn()
    |> put_req_header("content-type", "application/vnd.api+json")
    |> patch(
      "/api/recordings/#{id}",
      Jason.encode!(%{data: %{type: "recordings", id: id, attributes: %{state: "stopped"}}})
    )
    |> json_response(200)
  end
end
