defmodule VisionApiWeb.ExporterStatusTest do
  use VisionApiWeb.ChannelCase, async: false

  import Phoenix.ConnTest, only: [build_conn: 0, get: 2, json_response: 2]

  @moduletag :capture_log

  # An exporter whose status/1 answers something that is no status.
  defmodule Malformed do
    @behaviour VisionCore.Exporter

    @impl VisionCore.Exporter
    def describe(_options), do: %{id: :malformed, name: "Malformed"}

    @impl VisionCore.Exporter
    def outputs(_options), do: []

    @impl VisionCore.Exporter
    def init(_options), do: {:ok, nil}

    @impl VisionCore.Exporter
    def handle_output(_output, _value, state), do: {:ok, state}

    @impl VisionCore.Exporter
    def status(_state), do: :ok
  end

  defmodule Composer do
    @behaviour VisionCore.Composer

    @impl VisionCore.Composer
    def config(_arm), do: %VisionCore.Config{exporters: [{Malformed, []}]}
  end

  setup do
    Application.stop(:vision_core)
    Application.put_env(:vision_core, :vehicle, Composer)
    {:ok, _apps} = Application.ensure_all_started(:vision_core)

    on_exit(fn ->
      Application.stop(:vision_core)
      Application.delete_env(:vision_core, :vehicle)
      Application.ensure_all_started(:vision_core)
    end)
  end

  @malformed %{"level" => "warning", "detail" => "Malformed status: :ok"}

  test "GET /api/exporters reports an exporter whose status is malformed as a warning" do
    assert %{"data" => [%{"id" => "malformed", "attributes" => %{"status" => status}}, _api]} =
             build_conn() |> get("/api/exporters") |> json_response(200)

    assert status == @malformed
  end

  test "the status channel goes on pushing the unit's status beside a malformed exporter status" do
    {:ok, _reply, _socket} =
      VisionApiWeb.DashboardSocket
      |> socket()
      |> subscribe_and_join(VisionApiWeb.StatusChannel, "status")

    assert_push "status", %{exporters: [%{id: "malformed", status: status}], hailo: "absent"}
    assert status == %{level: "warning", detail: "Malformed status: :ok"}
  end
end
