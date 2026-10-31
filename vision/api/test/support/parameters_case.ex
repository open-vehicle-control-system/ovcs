defmodule VisionApiWeb.ParametersCase do
  @moduledoc """
  Test case declaring the group `test.disparity` in a restarted `:vision_core`
  whose registry saves into memory. The declaring process is the test
  process, which stays alive for the test.
  """
  use ExUnit.CaseTemplate

  using do
    quote do
      use VisionApiWeb.ConnCase, async: false

      @moduletag :capture_log

      defp parameter(conn, id) do
        conn |> get("/api/parameters/#{id}") |> json_response(200) |> Map.fetch!("data")
      end
    end
  end

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

    start_supervised!(VisionApiWeb.MemoryStore)

    :sys.replace_state(
      VisionCore.Parameters,
      &%{&1 | store: VisionApiWeb.MemoryStore, saved: %{}}
    )

    values = start_supervised!({Agent, fn -> %{p1: 8, p2: 64, exposure: 100, auto: true} end})
    get = fn key -> fn -> Agent.get(values, & &1[key]) end end
    set = fn key -> fn value -> Agent.update(values, &Map.put(&1, key, value)) end end

    :ok =
      VisionCore.Parameters.declare([
        %{
          id: "test.disparity",
          name: "Disparity",
          summary: "Matches.",
          kind: :stage,
          placement: :flow,
          position: 2,
          status: fn -> {:ok, "fine"} end,
          parameters: [
            %{
              name: "p1",
              type: :integer,
              get: get.(:p1),
              set: set.(:p1),
              constraint: %{kind: :range, min: 0, max: 78, step: nil}
            },
            %{
              name: "p2",
              type: :integer,
              get: get.(:p2),
              set: set.(:p2),
              greater_than: "p1"
            },
            %{name: "width", type: :integer, get: fn -> 480 end, applies: :build},
            %{
              name: "exposure",
              type: :integer,
              get: get.(:exposure),
              set: set.(:exposure),
              applies: {:auto, "test.disparity.auto"}
            },
            %{
              name: "auto",
              type: :bool,
              get: get.(:auto),
              set: set.(:auto),
              constraint: %{kind: :bool}
            }
          ]
        }
      ])
  end
end
