defmodule VisionCore.Parameters.ChangesTest do
  use ExUnit.Case, async: true

  @moduletag :capture_log

  alias VisionCore.{Outputs, Parameters}
  alias VisionCore.Parameters.Group

  require Outputs

  defmodule Unsaved do
    @moduledoc false
    def load, do: %{}
    def write(_changes), do: :ok
  end

  @sample_interval_ms 50

  setup context do
    server = :"#{__MODULE__}.#{context.test}"

    start_supervised!(
      {Parameters,
       name: server, store: Unsaved, publish_delay_ms: 20, sample_interval_ms: @sample_interval_ms}
    )

    %{server: server}
  end

  # An owner declaring a stage with a live parameter `rate`, a status and a parameter `offset`
  # set automatically while `auto` is on, each read from an Agent the test changes.
  defp start_owner(server) do
    test = self()

    owner =
      spawn(fn ->
        {:ok, agent} =
          Agent.start_link(fn ->
            %{"rate" => 1, "auto" => true, "offset" => 0, "status" => {:ok, "steady"}}
          end)

        backed = fn name, type ->
          %{
            name: name,
            type: type,
            get: fn ->
              send(test, {:read, name})
              Agent.get(agent, & &1[name])
            end,
            set: fn value -> Agent.update(agent, &Map.put(&1, name, value)) end
          }
        end

        :ok =
          Parameters.declare(server, [
            %{
              id: "test.steady",
              name: "Steady",
              summary: "Changes only when set",
              kind: :stage,
              pipeline: :test,
              position: 1,
              parameters: [backed.("rate", :integer)]
            },
            %{
              id: "test.moving",
              name: "Moving",
              summary: "Changes on its own",
              kind: :stage,
              pipeline: :test,
              position: 2,
              status: fn -> Agent.get(agent, & &1["status"]) end,
              parameters: [
                backed.("auto", :bool),
                Map.put(backed.("offset", :integer), :applies, {:auto, "test.moving.auto"})
              ]
            }
          ])

        send(test, {:owner, self(), agent})
        Process.sleep(:infinity)
      end)

    assert_receive {:owner, ^owner, agent}
    {owner, agent}
  end

  defp listing(kind) do
    assert_receive Outputs.queued({:parameter_groups, ^kind, groups}), 1_000
    groups
  end

  defp value(groups, id) do
    for %Group{parameters: parameters} <- groups,
        %{id: ^id, value: value} <- parameters,
        do: value
  end

  test "sends a subscriber the listing as a component declares its groups and as one is set, once for a burst",
       %{server: server} do
    :ok = Outputs.subscribe(Parameters.changes_key(server))
    start_owner(server)
    assert [%Group{id: "test.steady"}, %Group{id: "test.moving"}] = listing(:all)

    {:ok, _parameter} = Parameters.set(server, "test.steady.rate", 2)
    {:ok, _parameter} = Parameters.set(server, "test.steady.rate", 3)

    assert value(listing(:all), "test.steady.rate") == [3]
    refute_receive Outputs.queued({:parameter_groups, :all, _groups}), 100
  end

  test "sends a subscriber the listing after a save and without a component's groups once it is gone",
       %{server: server} do
    {owner, _agent} = start_owner(server)
    :ok = Outputs.subscribe(Parameters.changes_key(server))
    {:ok, _parameter} = Parameters.set(server, "test.steady.rate", 2)

    assert [%{state: :unsaved}] =
             for(g <- listing(:all), p <- g.parameters, p.name == "rate", do: p)

    {:ok, _ids} = Parameters.save(server)

    assert [%{state: :saved}] =
             for(g <- listing(:all), p <- g.parameters, p.name == "rate", do: p)

    Process.exit(owner, :kill)
    assert listing(:all) == []
  end

  test "re-reads the statuses and the automatic parameters while subscribed, sending only the groups that changed",
       %{server: server} do
    {_owner, agent} = start_owner(server)
    :ok = Outputs.subscribe(Parameters.changes_key(server))
    {:ok, _parameter} = Parameters.set(server, "test.steady.rate", 2)
    listing(:all)

    Agent.update(agent, &Map.merge(&1, %{"offset" => 5, "status" => {:warning, "drifting"}}))

    assert [%Group{id: "test.moving", status: {:warning, "drifting"}} = moving] =
             listing(:changed)

    assert value([moving], "test.moving.offset") == [5]
    refute_receive Outputs.queued({:parameter_groups, _kind, _groups}), 4 * @sample_interval_ms
  end

  test "reads nothing while no one subscribes", %{server: server} do
    start_owner(server)
    flush_reads()
    Process.sleep(4 * @sample_interval_ms)
    refute_received {:read, _name}
  end

  defp flush_reads do
    receive do
      {:read, _name} -> flush_reads()
    after
      50 -> :ok
    end
  end
end
