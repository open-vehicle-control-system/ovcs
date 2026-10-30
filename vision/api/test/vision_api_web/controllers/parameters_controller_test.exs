defmodule VisionApiWeb.ParametersControllerTest do
  use VisionApiWeb.ConnCase, async: false

  @moduletag :capture_log

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

    gain = start_supervised!({Agent, fn -> 2 end})

    :ok =
      VisionCore.Parameters.declare([
        %{
          id: "test.group",
          name: "Test",
          summary: "A test group.",
          kind: :component,
          placement: :side,
          position: 0,
          parameters: [
            %{
              name: "gain",
              type: :integer,
              get: fn -> Agent.get(gain, & &1) end,
              set: fn value -> Agent.update(gain, fn _ -> value end) end,
              constraint: %{kind: :range, min: 1, max: 10, step: nil},
              description: "Gain"
            },
            %{name: "width", type: :integer, get: fn -> 480 end, applies: :build}
          ]
        }
      ])
  end

  test "GET /api/parameters lists the parameters with their constraints", %{conn: conn} do
    parameters = json_response(get(conn, "/api/parameters"), 200)["parameters"]

    assert %{
             "name" => "test.group.gain",
             "type" => "integer",
             "value" => 2,
             "read_only" => false,
             "range" => [1, 10],
             "description" => "Gain"
           } = Enum.find(parameters, &(&1["name"] == "test.group.gain"))

    assert %{"read_only" => true, "value" => 480} =
             Enum.find(parameters, &(&1["name"] == "test.group.width"))
  end

  test "PUT /api/parameters/:name sets a value", %{conn: conn} do
    assert json_response(put(conn, "/api/parameters/test.group.gain", %{value: 7}), 200) ==
             %{"name" => "test.group.gain", "value" => 7}

    assert {:ok, %{value: 7, state: :unsaved}} = VisionCore.Parameters.get("test.group.gain")
  end

  test "PUT /api/parameters/:name refuses a value out of range, fixed or unknown",
       %{conn: conn} do
    assert %{"error" => "out of range 1..10"} =
             json_response(put(conn, "/api/parameters/test.group.gain", %{value: 20}), 422)

    assert %{"error" => "fixed in the build"} =
             json_response(put(conn, "/api/parameters/test.group.width", %{value: 1}), 422)

    assert %{"error" => "unknown parameter"} =
             json_response(put(conn, "/api/parameters/nope", %{value: 1}), 422)
  end
end
