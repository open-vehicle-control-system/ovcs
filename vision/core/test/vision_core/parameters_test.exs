defmodule VisionCore.ParametersTest do
  use ExUnit.Case, async: true

  @moduletag :capture_log

  alias VisionCore.Parameters
  alias VisionCore.Parameters.MemoryStore

  @auto_exposure "stereo.cameras.auto_exposure"

  setup context do
    server = :"#{__MODULE__}.#{context.test}"
    start_supervised!({Parameters, name: server, store: MemoryStore})
    %{server: server}
  end

  test "lists declared groups with values read when asked and defaults from the first read",
       %{server: server} do
    {_owner, agent} = start_owner(server, &match_groups/1)
    Agent.update(agent, &Map.put(&1, "p1", 12))

    assert [%Parameters.Group{id: "stereo.match", kind: :stage, position: 2} = group] =
             Parameters.groups(server)

    assert [p1, p2] = group.parameters
    assert %{id: "stereo.match.p1", value: 12, default: 8, saved: nil, state: :unsaved} = p1
    assert %{id: "stereo.match.p2", greater_than: "stereo.match.p1", state: :builtin} = p2
  end

  test "lists groups sorted by position", %{server: server} do
    start_owner(server, &match_groups/1)
    start_owner(server, &cameras_groups(&1, false))

    assert ["stereo.cameras", "stereo.match"] = Enum.map(Parameters.groups(server), & &1.id)
  end

  test "an integer is accepted for a double and stored as a float", %{server: server} do
    start_owner(server, &cameras_groups(&1, false))

    assert {:ok, %{value: 2.0}} = Parameters.set(server, "stereo.cameras.analogue_gain", 2)
    assert_receive {:set, "analogue_gain", 2.0}
  end

  test "refuses a value of the wrong type, out of range, off-step or not among the choices",
       %{server: server} do
    start_owner(server, &match_groups/1)
    start_owner(server, &preview_groups/1)

    assert Parameters.set(server, "stereo.match.p1", "8") ==
             {:error, ~s(expected integer, got "8")}

    assert Parameters.set(server, "stereo.match.p1", 79) == {:error, "out of range 0..78"}

    assert Parameters.set(server, "preview.quality", 52) ==
             {:error, "not a multiple of 5 from 10"}

    assert Parameters.set(server, "preview.colormap", "hot") ==
             {:error, "expected one of jet, gray"}

    assert {:ok, %{value: 55}} = Parameters.set(server, "preview.quality", 55)
    assert {:ok, %{value: "gray"}} = Parameters.set(server, "preview.colormap", "gray")
  end

  test "refuses p2 at or below p1, and p1 at or above p2", %{server: server} do
    start_owner(server, &match_groups/1)

    assert Parameters.set(server, "stereo.match.p2", 8) ==
             {:error, "must be above stereo.match.p1 (8)"}

    assert Parameters.set(server, "stereo.match.p1", 64) ==
             {:error, "must stay below stereo.match.p2 (64)"}

    assert {:ok, %{value: 9}} = Parameters.set(server, "stereo.match.p2", 9)
  end

  test "refuses an unknown parameter", %{server: server} do
    assert Parameters.set(server, "stereo.match.p9", 1) == {:error, "unknown parameter"}
    assert Parameters.get(server, "stereo.match.p9") == {:error, :not_found}
  end

  test "refuses a build parameter", %{server: server} do
    start_owner(server, &cameras_groups(&1, false))

    assert Parameters.set(server, "stereo.cameras.width", 640) == {:error, "fixed in the build"}
    assert {:ok, %{value: 768, state: :builtin}} = Parameters.get(server, "stereo.cameras.width")
  end

  test "refuses a parameter set by its automatic mode, and reports it :automatic",
       %{server: server} do
    start_owner(server, &cameras_groups(&1, true))

    assert Parameters.set(server, "stereo.cameras.exposure_us", 5000) ==
             {:error, "set by #{@auto_exposure} while it is on"}

    assert {:ok, %{state: :automatic}} = Parameters.get(server, "stereo.cameras.exposure_us")
    assert {:ok, %{state: :builtin}} = Parameters.get(server, @auto_exposure)
  end

  test "switching an automatic mode off keeps the values it left, as unsaved changes, set before the switch",
       %{server: server} do
    {_owner, agent} = start_owner(server, &cameras_groups(&1, true))
    Agent.update(agent, &%{&1 | "exposure_us" => 8000, "analogue_gain" => 2.0})

    assert {:ok, %{value: false}} = Parameters.set(server, @auto_exposure, false)

    assert receive_sets(3) == [
             {"exposure_us", 8000},
             {"analogue_gain", 2.0},
             {"auto_exposure", false}
           ]

    assert {:ok, %{state: :unsaved, value: 8000, default: 10_000}} =
             Parameters.get(server, "stereo.cameras.exposure_us")

    assert Parameters.unsaved_count(server) == 3
  end

  test "a refused set changes nothing", %{server: server} do
    {_owner, agent} = start_owner(server, &match_groups/1)

    assert {:error, _reason} = Parameters.set(server, "stereo.match.p1", 79)
    refute_receive {:set, _name, _value}
    assert Agent.get(agent, & &1["p1"]) == 8
    assert {:ok, %{value: 8, state: :builtin}} = Parameters.get(server, "stereo.match.p1")
    assert Parameters.unsaved_count(server) == 0
  end

  test "a set the owner refuses, raises on or exits from is refused with its reason",
       %{server: server} do
    start_owner(server, &failing_groups/1)

    assert Parameters.set(server, "failing.refuses", 1) == {:error, "busy"}
    assert Parameters.set(server, "failing.raises", 1) == {:error, "broken"}
    assert {:error, "not applied: " <> _reason} = Parameters.set(server, "failing.exits", 1)
  end

  test "an owner's groups go when it exits", %{server: server} do
    {owner, _agent} = start_owner(server, &match_groups/1)
    stop_owner(owner)

    assert Parameters.groups(server) == []
    assert Parameters.get(server, "stereo.match.p1") == {:error, :not_found}
  end

  test "a second declaration replaces the owner's earlier groups", %{server: server} do
    {owner, _agent} = start_owner(server, &match_groups/1)
    send(owner, {:declare, preview_groups(self()) |> elem(0)})
    assert_receive {:declared, ^owner}

    assert ["preview"] = Enum.map(Parameters.groups(server), & &1.id)
  end

  test "a re-declared group gets back the values set through the registry", %{server: server} do
    {owner, _agent} = start_owner(server, &match_groups/1)
    assert {:ok, _parameter} = Parameters.set(server, "stereo.match.p1", 12)
    assert_receive {:set, "p1", 12}
    stop_owner(owner)

    {_owner, agent} = start_owner(server, &match_groups/1)

    assert_receive {:set, "p1", 12}
    refute_receive {:set, "p2", _value}
    assert Agent.get(agent, & &1["p1"]) == 12

    assert {:ok, %{value: 12, default: 8, state: :unsaved}} =
             Parameters.get(server, "stereo.match.p1")
  end

  test "a re-declared automatic mode is switched off before the values it controls are set back",
       %{server: server} do
    {owner, _agent} = start_owner(server, &cameras_groups(&1, true))
    assert {:ok, _parameter} = Parameters.set(server, @auto_exposure, false)
    assert {:ok, _parameter} = Parameters.set(server, "stereo.cameras.exposure_us", 5000)
    assert length(receive_sets(4)) == 4
    stop_owner(owner)

    start_owner(server, &cameras_groups(&1, true))

    assert receive_sets(3) == [
             {"auto_exposure", false},
             {"exposure_us", 5000},
             {"analogue_gain", 1.0}
           ]

    assert {:ok, %{value: 5000, state: :unsaved}} =
             Parameters.get(server, "stereo.cameras.exposure_us")
  end

  test "a value set back on re-declaration is skipped while its automatic mode is on",
       %{server: server} do
    {owner, _agent} = start_owner(server, &cameras_groups(&1, false))
    assert {:ok, _parameter} = Parameters.set(server, "stereo.cameras.exposure_us", 5000)
    assert_receive {:set, "exposure_us", 5000}
    stop_owner(owner)

    start_owner(server, &cameras_groups(&1, true))
    refute_receive {:set, _name, _value}

    assert {:ok, %{value: 10_000, state: :automatic}} =
             Parameters.get(server, "stereo.cameras.exposure_us")
  end

  test "a get that exits lists the parameter with a nil value", %{server: server} do
    start_owner(server, &failing_groups/1)

    [group] = Parameters.groups(server)
    assert %{value: nil, default: nil} = Enum.find(group.parameters, &(&1.name == "unreadable"))
  end

  test "a group's status is listed, and nil when its function fails", %{server: server} do
    start_owner(server, &match_groups/1)
    start_owner(server, &failing_groups/1)

    statuses = Map.new(Parameters.groups(server), &{&1.id, &1.status})
    assert statuses == %{"stereo.match" => {:ok, "matching"}, "failing" => nil}
  end

  test "unsaved_count counts parameters whose value differs from their default",
       %{server: server} do
    start_owner(server, &match_groups/1)
    assert Parameters.unsaved_count(server) == 0

    assert {:ok, _parameter} = Parameters.set(server, "stereo.match.p1", 12)
    assert Parameters.unsaved_count(server) == 1

    assert {:ok, _parameter} = Parameters.set(server, "stereo.match.p1", 8)
    assert Parameters.unsaved_count(server) == 0
  end

  # An owner process holding the Agent behind its parameters; both go when it is killed.
  defp start_owner(server, groups_fun) do
    test = self()

    owner =
      spawn(fn ->
        {groups, agent} = groups_fun.(test)
        send(test, {:agent, self(), agent})
        owner_loop(server, test, groups)
      end)

    assert_receive {:agent, ^owner, agent}
    assert_receive {:declared, ^owner}
    # Waits for the registry to finish applying the declaration.
    :sys.get_state(server)
    {owner, agent}
  end

  defp owner_loop(server, test, groups) do
    :ok = Parameters.declare(server, groups)
    send(test, {:declared, self()})

    receive do
      {:declare, groups} -> owner_loop(server, test, groups)
    end
  end

  defp stop_owner(owner) do
    reference = Process.monitor(owner)
    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^reference, :process, ^owner, :killed}
  end

  defp receive_sets(count) do
    for _index <- 1..count do
      assert_receive {:set, name, value}
      {name, value}
    end
  end

  defp match_groups(test) do
    {:ok, agent} = Agent.start_link(fn -> %{"p1" => 8, "p2" => 64} end)

    group = %{
      id: "stereo.match",
      name: "Match",
      summary: "Matches the rectified rows",
      kind: :stage,
      placement: :flow,
      position: 2,
      status: fn -> {:ok, "matching"} end,
      parameters: [
        backed(agent, test, "p1", :integer, %{kind: :range, min: 0, max: 78, step: nil}),
        backed(agent, test, "p2", :integer, %{kind: :range, min: 1, max: 79, step: nil})
        |> Map.put(:greater_than, "p1")
      ]
    }

    {[group], agent}
  end

  defp cameras_groups(test, auto_exposure) do
    {:ok, agent} =
      Agent.start_link(fn ->
        %{"auto_exposure" => auto_exposure, "exposure_us" => 10_000, "analogue_gain" => 1.0}
      end)

    automatic = {:auto, @auto_exposure}

    group = %{
      id: "stereo.cameras",
      name: "Cameras",
      summary: "Captures the left and right frames",
      kind: :component,
      placement: :flow,
      position: 0,
      parameters: [
        backed(agent, test, "auto_exposure", :bool, %{kind: :bool}),
        backed(agent, test, "exposure_us", :integer, %{
          kind: :range,
          min: 100,
          max: 1_000_000,
          step: nil
        })
        |> Map.put(:applies, automatic),
        backed(agent, test, "analogue_gain", :double, %{kind: :range, min: 1, max: 16, step: nil})
        |> Map.put(:applies, automatic),
        %{name: "width", type: :integer, applies: :build, get: fn -> 768 end}
      ]
    }

    {[group], agent}
  end

  defp preview_groups(test) do
    {:ok, agent} = Agent.start_link(fn -> %{"quality" => 80, "colormap" => "jet"} end)

    group = %{
      id: "preview",
      name: "Preview",
      summary: "Encodes the preview images",
      kind: :component,
      placement: :side,
      position: 5,
      parameters: [
        backed(agent, test, "quality", :integer, %{kind: :range, min: 10, max: 100, step: 5}),
        backed(agent, test, "colormap", :string, %{kind: :choices, values: ["jet", "gray"]})
      ]
    }

    {[group], agent}
  end

  defp failing_groups(_test) do
    range = %{kind: :range, min: 0, max: 10, step: nil}
    readable = fn -> 0 end

    group = %{
      id: "failing",
      name: "Failing",
      summary: "Fails",
      kind: :stage,
      placement: :side,
      position: 9,
      status: fn -> raise "no status" end,
      parameters: [
        %{name: "unreadable", type: :integer, constraint: range, get: fn -> exit(:gone) end},
        %{
          name: "refuses",
          type: :integer,
          constraint: range,
          get: readable,
          set: fn _value -> {:error, "busy"} end
        },
        %{
          name: "raises",
          type: :integer,
          constraint: range,
          get: readable,
          set: fn _value -> raise "broken" end
        },
        %{
          name: "exits",
          type: :integer,
          constraint: range,
          get: readable,
          set: fn _value -> exit(:gone) end
        }
      ]
    }

    {[group], nil}
  end

  defp backed(agent, test, name, type, constraint) do
    %{
      name: name,
      type: type,
      constraint: constraint,
      get: fn -> Agent.get(agent, & &1[name]) end,
      set: fn value ->
        Agent.update(agent, &Map.put(&1, name, value))
        send(test, {:set, name, value})
        :ok
      end
    }
  end
end
