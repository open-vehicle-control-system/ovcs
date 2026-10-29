defmodule VisionApiWeb.ParametersControllerTest do
  use VisionApiWeb.ConnCase, async: false

  alias VisionCore.Ros2.Parameters

  defmodule Composer do
    @behaviour VisionCore.Composer

    @impl VisionCore.Composer
    def config(_arm) do
      %VisionCore.Config{zenoh_endpoint_ip: "127.0.0.1", node_name: "vision_test", components: []}
    end
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

    :ok =
      Parameters.declare([
        %{
          name: "test.gain",
          type: :integer,
          value: 2,
          range: {1, 10},
          description: "Gain",
          set: fn _value -> :ok end
        },
        %{name: "test.width", type: :integer, value: 480, read_only: true}
      ])
  end

  test "GET /api/parameters lists the parameters with their constraints", %{conn: conn} do
    parameters = json_response(get(conn, "/api/parameters"), 200)["parameters"]

    assert %{
             "name" => "test.gain",
             "type" => "integer",
             "value" => 2,
             "read_only" => false,
             "range" => [1, 10],
             "description" => "Gain"
           } = Enum.find(parameters, &(&1["name"] == "test.gain"))

    assert %{"read_only" => true} = Enum.find(parameters, &(&1["name"] == "test.width"))
  end

  test "PUT /api/parameters/:name sets a value", %{conn: conn} do
    assert json_response(put(conn, "/api/parameters/test.gain", %{value: 7}), 200) ==
             %{"name" => "test.gain", "value" => 7}

    assert Enum.find(Parameters.list(), &(&1.name == "test.gain")).value == 7
  end

  test "PUT /api/parameters/:name refuses a value out of range or read-only", %{conn: conn} do
    assert %{"error" => "out of range 1..10"} =
             json_response(put(conn, "/api/parameters/test.gain", %{value: 20}), 422)

    assert %{"error" => "read-only" <> _} =
             json_response(put(conn, "/api/parameters/test.width", %{value: 1}), 422)
  end
end
