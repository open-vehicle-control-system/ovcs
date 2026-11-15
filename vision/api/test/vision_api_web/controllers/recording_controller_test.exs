defmodule VisionApiWeb.RecordingControllerTest do
  use VisionApiWeb.ConnCase, async: false

  import VisionApiWeb.RefusalTests

  alias VisionApiWeb.{AnsweringBag, TestDisks}
  alias VisionCore.Ros2.Bag.Metadata

  @moduletag :tmp_dir
  @moduletag :capture_log

  @media_type "application/vnd.api+json"
  @stopped "20250101T090000Z_review"

  setup %{tmp_dir: tmp_dir} do
    %{disks: TestDisks.start_unit(tmp_dir)}
  end

  # A recording the bag exporter left, in two parts on the unit's storage.
  defp stopped!(%{disks: disks}) do
    for {folder, starting_ns} <- [
          {@stopped, 1_000_000_000},
          {@stopped <> "_part2", 61_000_000_000}
        ] do
      dir = Path.join(disks[:internal], folder)
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "#{folder}_0.mcap"), :binary.copy(<<0>>, 1_000))

      metadata = %{
        files: [
          %{
            path: "#{folder}_0.mcap",
            starting_time: starting_ns,
            duration: 60_000_000_000,
            message_count: 30
          }
        ],
        topics: [
          %{
            name: "/tf",
            type: "tf2_msgs/msg/TFMessage",
            type_description_hash: "",
            offered_qos_profiles: [],
            message_count: 30
          }
        ],
        custom_data: %{
          "preset" => "review",
          "clock" => "automatic",
          "clock_in_use" => "since_start",
          "clock_synchronized" => "false",
          "started_at" => "2025-01-01T09:00:00.000000Z",
          "dropped:/tf" => "2"
        },
        ros_distro: "lyrical"
      }

      File.write!(Path.join(dir, "metadata.yaml"), Metadata.encode(metadata))
    end

    :ok
  end

  defp jsonapi(conn), do: put_req_header(conn, "content-type", @media_type)

  defp start_recording(conn, attributes \\ %{}),
    do: post_document(conn, "/api/recordings", %{type: "recordings", attributes: attributes})

  defp started!(conn) do
    %{"data" => %{"id" => id}} = conn |> start_recording() |> json_response(201)
    id
  end

  defp change(conn, id, attributes) do
    document = %{data: %{type: "recordings", id: id, attributes: attributes}}
    conn |> jsonapi() |> patch("/api/recordings/#{id}", Jason.encode!(document))
  end

  defp stop!(conn, id), do: conn |> change(id, %{state: "stopped"}) |> json_response(200)

  describe "GET /api/recordings" do
    test "lists the recordings, the newest first, with their facts", %{conn: conn} = context do
      stopped!(context)
      id = started!(conn)

      conn = get(build_conn(), "/api/recordings")
      assert get_resp_header(conn, "content-type") == [@media_type]
      assert %{"data" => [recording, stopped]} = json_response(conn, 200)

      assert %{
               "type" => "recordings",
               "id" => ^id,
               "attributes" => %{"name" => ^id, "state" => "recording", "preset" => "review"},
               "relationships" => %{
                 "disk" => %{"data" => %{"type" => "disks", "id" => "internal"}}
               }
             } = recording

      assert %{
               "type" => "recordings",
               "id" => @stopped,
               "attributes" => %{
                 "name" => @stopped,
                 "state" => "stopped",
                 "preset" => "review",
                 "clock" => "automatic",
                 "clockInUse" => "since_start",
                 "clockSynchronized" => false,
                 "startedAt" => "2025-01-01T09:00:00.000000Z",
                 "durationMs" => 120_000,
                 "bytes" => bytes,
                 "messages" => 60,
                 "dropped" => [%{"topic" => "/tf", "count" => 4}]
               },
               "relationships" => %{
                 "disk" => %{"data" => nil},
                 "parts" => %{
                   "data" => [
                     %{"type" => "recording-parts", "id" => @stopped},
                     %{"type" => "recording-parts", "id" => @stopped <> "_part2"}
                   ]
                 }
               }
             } = stopped

      assert bytes > 2_000
      stop!(build_conn(), id)
    end

    test "with include=parts, has each part with its number, bytes and disk",
         %{conn: conn} = context do
      stopped!(context)

      assert %{"included" => [first, second]} =
               conn |> get("/api/recordings?include=parts") |> json_response(200)

      assert %{
               "type" => "recording-parts",
               "id" => @stopped,
               "attributes" => %{"name" => @stopped, "number" => 1, "bytes" => bytes},
               "relationships" => %{
                 "disk" => %{"data" => %{"type" => "disks", "id" => "internal"}}
               }
             } = first

      assert bytes > 1_000
      assert %{"attributes" => %{"number" => 2}} = second
    end

    test "answers 400 for another include", %{conn: conn} do
      assert %{"errors" => [%{"status" => "400", "source" => %{"parameter" => "include"}}]} =
               conn |> get("/api/recordings?include=disks") |> json_response(400)
    end

    test "answers 504 or 500 when the bag exporter does not say what it records",
         %{conn: conn} = context do
      stopped!(context)

      for {answer, status} <- [
            {{:error, :timeout}, 504},
            {{:error, {:failed, "crashed"}}, 500},
            {{:error, :unknown_call}, 500}
          ] do
        AnsweringBag.answer(answer)

        for path <- ["/api/recordings", "/api/recordings/#{@stopped}"] do
          assert %{"errors" => [%{"status" => status_text}]} =
                   conn |> get(path) |> json_response(status)

          assert status_text == Integer.to_string(status)
        end
      end
    end

    test "is empty on a unit without a bag exporter", %{conn: conn} do
      VisionApiWeb.TestUnit.start(%VisionCore.Config{})

      assert %{"data" => []} = conn |> get("/api/recordings") |> json_response(200)
    end
  end

  describe "GET /api/recordings/:id" do
    test "answers the recording", %{conn: conn} = context do
      stopped!(context)

      assert %{"data" => %{"id" => @stopped, "attributes" => %{"state" => "stopped"}}} =
               conn |> get("/api/recordings/#{@stopped}") |> json_response(200)
    end

    test "answers 404 for a name no recording has, a part's among them",
         %{conn: conn} = context do
      stopped!(context)

      for id <- ["20261115T000000Z_review", @stopped <> "_part2", "..%2Frecordings"] do
        assert %{"errors" => [%{"status" => "404", "detail" => detail}]} =
                 conn |> get("/api/recordings/#{id}") |> json_response(404)

        assert detail =~ "no recording"
      end
    end
  end

  describe "POST /api/recordings" do
    test "starts a recording, review on the automatic clock by default", %{conn: conn} do
      conn = start_recording(conn)

      assert get_resp_header(conn, "content-type") == [@media_type]

      assert %{
               "data" => %{
                 "type" => "recordings",
                 "id" => id,
                 "attributes" => %{
                   "state" => "recording",
                   "preset" => "review",
                   "clock" => "automatic",
                   "clockInUse" => "system"
                 },
                 "relationships" => %{"disk" => %{"data" => %{"id" => "internal"}}}
               }
             } = json_response(conn, 201)

      assert id =~ ~r/^\d{8}T\d{6}Z_review$/
      stop!(build_conn(), id)
    end

    test "starts the preset on the clock its attributes name", %{conn: conn} do
      conn = start_recording(conn, %{preset: "replay", clock: "since_start"})

      assert %{
               "data" => %{
                 "id" => id,
                 "attributes" => %{"preset" => "replay", "clock" => "since_start"}
               }
             } =
               json_response(conn, 201)

      stop!(build_conn(), id)
    end

    test "answers 422 for a preset or a clock it does not have", %{conn: conn} do
      for {attributes, member, allowed} <- [
            {%{preset: "fast"}, "preset", "replay, review"},
            {%{preset: 3}, "preset", "replay, review"},
            {%{clock: "gps"}, "clock", "system, since_start, automatic"}
          ] do
        assert %{"errors" => [%{"status" => "422", "detail" => detail, "source" => source}]} =
                 conn |> start_recording(attributes) |> json_response(422)

        assert source == %{"pointer" => "/data/attributes/#{member}"}
        assert detail =~ allowed
      end
    end

    test "answers 400 for attributes that are no object", %{conn: conn} do
      assert %{"errors" => [%{"status" => "400", "source" => %{"pointer" => "/data/attributes"}}]} =
               conn
               |> post_document("/api/recordings", %{type: "recordings", attributes: "review"})
               |> json_response(400)
    end

    test "answers 409 while a recording records", %{conn: conn} do
      id = started!(conn)

      assert %{"errors" => [%{"status" => "409", "detail" => detail}]} =
               build_conn() |> start_recording() |> json_response(409)

      assert detail =~ "in progress"
      stop!(build_conn(), id)
    end

    test "answers 409 with no disk to record on", %{conn: conn} do
      :ok = VisionCore.Disks.put_enabled(VisionCore.Disks, "internal", false)

      assert %{"errors" => [%{"status" => "409", "detail" => detail}]} =
               conn |> start_recording() |> json_response(409)

      assert detail =~ "no disk"
    end

    test "answers 404 on a unit without a bag exporter", %{conn: conn} do
      VisionApiWeb.TestUnit.start(%VisionCore.Config{})

      assert %{"errors" => [%{"status" => "404", "detail" => detail}]} =
               conn |> start_recording() |> json_response(404)

      assert detail =~ "bag exporter"
    end

    test "answers 504 when the bag exporter does not answer in time, the start maybe done",
         %{conn: conn} do
      AnsweringBag.answer({:error, :timeout})

      assert %{"errors" => [%{"status" => "504", "detail" => detail}]} =
               conn |> start_recording() |> json_response(504)

      assert detail =~ "may have started"
    end

    test "answers 503 while the bag exporter does not run", %{conn: conn} do
      :ok = Supervisor.terminate_child(VisionCore.Exporters, :ros2_bag)

      assert %{"errors" => [%{"status" => "503"}]} =
               conn |> start_recording() |> json_response(503)
    end

    test_document_refusals("/api/recordings", "recordings")
  end

  describe "PATCH /api/recordings/:id" do
    test "stops the recording", %{conn: conn} do
      id = started!(conn)

      assert %{"data" => %{"id" => ^id, "attributes" => %{"state" => "stopped"}}} =
               stop!(build_conn(), id)

      assert %{"data" => %{"attributes" => %{"state" => "stopped"}}} =
               build_conn() |> get("/api/recordings/#{id}") |> json_response(200)
    end

    test "answers 422 for another state, and for a recording stopped already",
         %{conn: conn} = context do
      stopped!(context)
      id = started!(conn)

      for {id, state} <- [{id, "recording"}, {id, 1}, {@stopped, "stopped"}] do
        assert %{"errors" => [%{"status" => "422", "source" => %{"pointer" => pointer}}]} =
                 build_conn() |> change(id, %{state: state}) |> json_response(422)

        assert pointer == "/data/attributes/state"
      end

      stop!(build_conn(), id)
    end

    test "answers 400 without a state", %{conn: conn} = context do
      stopped!(context)

      for attributes <- [%{}, nil] do
        assert %{"errors" => [%{"status" => "400", "source" => %{"pointer" => pointer}}]} =
                 conn |> change(@stopped, attributes) |> json_response(400)

        assert pointer == "/data/attributes/state"
      end
    end

    test "answers 404 for a name no recording has", %{conn: conn} do
      assert %{"errors" => [%{"status" => "404"}]} =
               conn
               |> change("20261115T000000Z_review", %{state: "stopped"})
               |> json_response(404)
    end

    test "answers 504 when the bag exporter does not answer in time, the stop maybe done",
         %{conn: conn} = context do
      stopped!(context)
      AnsweringBag.answer({:error, :timeout})

      assert %{"errors" => [%{"status" => "504", "detail" => detail}]} =
               conn |> change(@stopped, %{state: "stopped"}) |> json_response(504)

      assert detail =~ "may still stop"
    end

    test_change_refusals("/api/recordings/#{@stopped}", "recordings", @stopped)
  end

  describe "DELETE /api/recordings/:id" do
    test "deletes every part of the recording", %{conn: conn} = context do
      stopped!(context)

      assert conn |> delete("/api/recordings/#{@stopped}") |> response(204) == ""
      assert File.ls!(context.disks[:internal]) == []
    end

    test "answers 409 while it records, 404 for a name no recording has", %{conn: conn} do
      id = started!(conn)

      assert %{"errors" => [%{"status" => "409"}]} =
               build_conn() |> delete("/api/recordings/#{id}") |> json_response(409)

      assert %{"errors" => [%{"status" => "404"}]} =
               build_conn()
               |> delete("/api/recordings/20261115T000000Z_review")
               |> json_response(404)

      stop!(build_conn(), id)
    end
  end
end
