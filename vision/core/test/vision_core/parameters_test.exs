defmodule VisionCore.ParametersTest do
  use ExUnit.Case, async: true

  @moduletag :capture_log

  alias VisionCore.Parameters
  alias VisionCore.Parameters.MemoryStore

  import ExUnit.CaptureLog

  defmodule FailingStore do
    @moduledoc false
    def load, do: %{}
    def write(_changes), do: {:error, "saved parameters unavailable"}
  end

  @auto_exposure "stereo.cameras.auto_exposure"

  # MemoryStore is one named Agent: other modules using it are synchronous, so run after these tests.
  setup context do
    if saved = context[:saved], do: start_supervised!({MemoryStore, saved})

    server = :"#{__MODULE__}.#{context.test}"
    start_supervised!({Parameters, name: server, store: context[:store] || MemoryStore})
    %{server: server}
  end

  test "lists declared groups with values read when asked and defaults from the first read",
       %{server: server} do
    {_owner, agent} = start_owner(server, &match_groups/1)
    Agent.update(agent, &Map.put(&1, "p1", 12))

    assert [%Parameters.Group{id: "stereo.disparity", kind: :stage, position: 2} = group] =
             Parameters.groups(server)

    assert [p1, p2] = group.parameters
    assert %{id: "stereo.disparity.p1", value: 12, default: 8, saved: nil, state: :unsaved} = p1
    assert %{id: "stereo.disparity.p2", greater_than: "stereo.disparity.p1", state: :builtin} = p2
  end

  test "a declared default wins over the first read", %{server: server} do
    start_owner(server, fn test ->
      {[group], agent} = match_groups(test)
      [p1, p2] = group.parameters
      {[%{group | parameters: [Map.put(p1, :default, 5), p2]}], agent}
    end)

    assert {:ok, %{value: 8, default: 5, state: :unsaved}} =
             Parameters.get(server, "stereo.disparity.p1")

    assert {:ok, %{default: 64}} = Parameters.get(server, "stereo.disparity.p2")
  end

  test "a group keeps where its work runs, and has none by default", %{server: server} do
    compute = %{runs_on: :gpu, implementation: :nx, backend: :vulkan}

    :ok =
      Parameters.declare(server, [
        %{
          id: "a",
          name: "A",
          summary: "",
          kind: :stage,
          placement: :flow,
          position: 1,
          compute: compute,
          parameters: []
        },
        %{
          id: "b",
          name: "B",
          summary: "",
          kind: :component,
          placement: :flow,
          position: 0,
          parameters: []
        }
      ])

    assert [%{id: "b", compute: nil}, %{id: "a", compute: ^compute}] = Parameters.groups(server)
  end

  test "lists groups sorted by position", %{server: server} do
    start_owner(server, &match_groups/1)
    start_owner(server, &cameras_groups(&1, false))

    assert ["stereo.cameras", "stereo.disparity"] = Enum.map(Parameters.groups(server), & &1.id)
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

    assert Parameters.set(server, "stereo.disparity.p1", "8") ==
             {:error, ~s(expected integer, got "8")}

    assert Parameters.set(server, "stereo.disparity.p1", 79) == {:error, "out of range 0..78"}

    assert Parameters.set(server, "preview.quality", 52) ==
             {:error, "not a multiple of 5 from 10"}

    assert Parameters.set(server, "preview.colormap", "hot") ==
             {:error, "expected one of jet, gray"}

    assert Parameters.set(server, "preview.mode", "manual") ==
             {:error, "expected one of {:fixed, 2}, auto, nil"}

    assert {:ok, %{value: 55}} = Parameters.set(server, "preview.quality", 55)
    assert {:ok, %{value: "gray"}} = Parameters.set(server, "preview.colormap", "gray")
  end

  test "refuses p2 at or below p1, and p1 at or above p2", %{server: server} do
    start_owner(server, &match_groups/1)

    assert Parameters.set(server, "stereo.disparity.p2", 8) ==
             {:error, "must be above stereo.disparity.p1 (8)"}

    assert Parameters.set(server, "stereo.disparity.p1", 64) ==
             {:error, "must stay below stereo.disparity.p2 (64)"}

    assert {:ok, %{value: 9}} = Parameters.set(server, "stereo.disparity.p2", 9)
  end

  test "refuses an unknown parameter", %{server: server} do
    assert Parameters.set(server, "stereo.disparity.p9", 1) == {:error, "unknown parameter"}
    assert Parameters.get(server, "stereo.disparity.p9") == {:error, :not_found}
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

  test "switching an automatic mode off brings the value it left within the controlled range",
       %{server: server} do
    {_owner, agent} = start_owner(server, &cameras_groups(&1, true))
    Agent.update(agent, &%{&1 | "exposure_us" => 50, "analogue_gain" => 20.0})

    assert {:ok, %{value: false}} = Parameters.set(server, @auto_exposure, false)

    assert receive_sets(3) == [
             {"exposure_us", 100},
             {"analogue_gain", 16.0},
             {"auto_exposure", false}
           ]
  end

  test "a refused set is logged once, at info", %{server: server} do
    log = capture_log([level: :info], fn -> Parameters.set(server, "stereo.disparity.p9", 1) end)

    assert log =~ "[info]"
    assert log =~ "vision parameter stereo.disparity.p9 = 1 refused: unknown parameter"
  end

  test "a refused set changes nothing", %{server: server} do
    {_owner, agent} = start_owner(server, &match_groups/1)

    assert {:error, _reason} = Parameters.set(server, "stereo.disparity.p1", 79)
    refute_receive {:set, _name, _value}
    assert Agent.get(agent, & &1["p1"]) == 8
    assert {:ok, %{value: 8, state: :builtin}} = Parameters.get(server, "stereo.disparity.p1")
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
    assert Parameters.get(server, "stereo.disparity.p1") == {:error, :not_found}
  end

  test "a second declaration replaces the owner's earlier groups", %{server: server} do
    {owner, _agent} = start_owner(server, &match_groups/1)
    send(owner, {:declare, preview_groups(self()) |> elem(0)})
    assert_receive {:declared, ^owner}

    assert ["preview"] = Enum.map(Parameters.groups(server), & &1.id)
  end

  test "a re-declared group gets back the values set through the registry", %{server: server} do
    {owner, _agent} = start_owner(server, &match_groups/1)
    assert {:ok, _parameter} = Parameters.set(server, "stereo.disparity.p1", 12)
    assert_receive {:set, "p1", 12}
    stop_owner(owner)

    {_owner, agent} = start_owner(server, &match_groups/1)

    assert_receive {:set, "p1", 12}
    refute_receive {:set, "p2", _value}
    assert Agent.get(agent, & &1["p1"]) == 12

    assert {:ok, %{value: 12, default: 8, state: :unsaved}} =
             Parameters.get(server, "stereo.disparity.p1")
  end

  test "a re-declared automatic mode is switched off before the values it controls are set back",
       %{server: server} do
    {owner, _agent} = start_owner(server, &cameras_groups(&1, true))
    assert {:ok, _parameter} = Parameters.set(server, @auto_exposure, false)
    assert {:ok, _parameter} = Parameters.set(server, "stereo.cameras.exposure_us", 5000)
    assert length(receive_sets(4)) == 4
    stop_owner(owner)

    start_owner(server, &cameras_groups(&1, true))

    assert receive_sets(5) == [
             {"exposure_us", 10_000},
             {"analogue_gain", 1.0},
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
    assert statuses == %{"stereo.disparity" => {:ok, "matching"}, "failing" => nil}
  end

  test "unsaved_count counts parameters whose value differs from their default",
       %{server: server} do
    start_owner(server, &match_groups/1)
    assert Parameters.unsaved_count(server) == 0

    assert {:ok, _parameter} = Parameters.set(server, "stereo.disparity.p1", 12)
    assert Parameters.unsaved_count(server) == 1

    assert {:ok, _parameter} = Parameters.set(server, "stereo.disparity.p1", 8)
    assert Parameters.unsaved_count(server) == 0
  end

  test "a get, set or status that throws is read as nil or refused", %{server: server} do
    start_owner(server, &throwing_groups/1)

    assert [%{status: nil, parameters: [%{value: nil}]}] = Parameters.groups(server)
    assert Parameters.set(server, "throwing.throws", 1) == {:error, "not applied: :busy"}
  end

  test "a parameter whose value cannot be read is never unsaved", %{server: server} do
    {_owner, agent} = start_owner(server, &match_groups/1)
    assert {:ok, _parameter} = Parameters.set(server, "stereo.disparity.p1", 12)
    Agent.update(agent, &Map.put(&1, "p1", nil))

    assert {:ok, %{value: nil, default: 8, state: :builtin}} =
             Parameters.get(server, "stereo.disparity.p1")

    assert Parameters.unsaved_count(server) == 0
  end

  describe "saved values" do
    @describetag saved: %{}

    @tag saved: %{"stereo.disparity.p1" => 10}
    test "a declared group gets its saved values", %{server: server} do
      start_owner(server, &match_groups/1)

      assert_receive {:set, "p1", 10}
      refute_receive {:set, "p2", _value}

      assert {:ok, %{value: 10, default: 8, saved: 10, state: :saved}} =
               Parameters.get(server, "stereo.disparity.p1")

      assert Parameters.unsaved_count(server) == 0
    end

    @tag saved: %{"stereo.disparity.p1" => 70, "stereo.disparity.p2" => 75}
    test "saved values of a related pair are applied in an order that keeps the relation",
         %{server: server} do
      log = capture_log(fn -> start_owner(server, &match_groups/1) end)

      assert receive_sets(2) == [{"p2", 75}, {"p1", 70}]
      refute log =~ "dropped"
      assert MemoryStore.rows() == %{"stereo.disparity.p1" => 70, "stereo.disparity.p2" => 75}
      assert {:ok, %{value: 70, state: :saved}} = Parameters.get(server, "stereo.disparity.p1")
    end

    @tag saved: %{"stereo.disparity.p1" => 200}
    test "a saved value that no longer fits is dropped and logged, and the group starts on its defaults",
         %{server: server} do
      log = capture_log(fn -> start_owner(server, &match_groups/1) end)

      assert log =~ "stereo.disparity.p1 = 200 dropped: out of range 0..78"
      refute_receive {:set, _name, _value}
      assert MemoryStore.rows() == %{}

      assert {:ok, %{value: 8, saved: nil, state: :builtin}} =
               Parameters.get(server, "stereo.disparity.p1")
    end

    @tag saved: %{"failing.refuses" => 3}
    test "a saved value its owner fails to set is kept and not applied", %{server: server} do
      log = capture_log(fn -> start_owner(server, &failing_groups/1) end)

      assert log =~ "failing.refuses = 3 kept, not applied: busy"
      refute log =~ "dropped"
      assert MemoryStore.rows() == %{"failing.refuses" => 3}
      assert {:ok, %{value: 0}} = Parameters.get(server, "failing.refuses")
    end

    @tag saved: %{"stereo.disparity.p3" => 1, "stereo.disparity.p1" => 10}
    test "a saved value of a parameter its group no longer declares is dropped",
         %{server: server} do
      log = capture_log(fn -> start_owner(server, &match_groups/1) end)

      assert log =~ "stereo.disparity.p3 = 1 dropped: no such parameter"
      assert MemoryStore.rows() == %{"stereo.disparity.p1" => 10}
    end

    @tag saved: %{"stereo.cameras.width" => 640, "stereo.cameras.exposure_us" => 5000}
    test "a saved value of a parameter now fixed in the build is dropped", %{server: server} do
      log = capture_log(fn -> start_owner(server, &cameras_groups(&1, false)) end)

      assert log =~ "stereo.cameras.width = 640 dropped: fixed in the build"
      assert MemoryStore.rows() == %{"stereo.cameras.exposure_us" => 5000}

      assert {:ok, %{saved: nil, state: :builtin}} =
               Parameters.get(server, "stereo.cameras.width")
    end

    @tag saved: %{"detection.min_score" => 0.5, "stereo.disparity_extra.p1" => 3}
    test "saved values of groups not declared yet are kept", %{server: server} do
      start_owner(server, &match_groups/1)

      assert MemoryStore.rows() == %{
               "detection.min_score" => 0.5,
               "stereo.disparity_extra.p1" => 3
             }
    end

    @tag saved: %{"stereo.cameras.auto_exposure" => false, "stereo.cameras.exposure_us" => 5000}
    test "a saved automatic mode is applied before the values it controls", %{server: server} do
      start_owner(server, &cameras_groups(&1, true))

      assert receive_sets(4) == [
               {"exposure_us", 10_000},
               {"analogue_gain", 1.0},
               {"auto_exposure", false},
               {"exposure_us", 5000}
             ]

      refute_receive {:set, _name, _value}
      assert Parameters.unsaved_count(server) == 0
    end

    @tag saved: %{"camera.auto_exposure" => false, "camera.exposure_us" => 20_000}
    test "a saved automatic mode whose owner's off does nothing is applied with its values",
         %{server: server} do
      {_owner, exposure} = start_owner(server, &switch_only_groups/1)

      assert Agent.get(exposure, & &1) == 20_000

      assert {:ok, %{value: false, state: :saved}} =
               Parameters.get(server, "camera.auto_exposure")

      assert {:ok, %{value: 20_000, state: :saved}} =
               Parameters.get(server, "camera.exposure_us")

      assert Parameters.save(server) == {:ok, []}

      assert MemoryStore.rows() == %{
               "camera.auto_exposure" => false,
               "camera.exposure_us" => 20_000
             }
    end

    @tag saved: %{"stereo.cameras.exposure_us" => 5000}
    test "a saved value is not applied while its automatic mode is on", %{server: server} do
      start_owner(server, &cameras_groups(&1, true))

      refute_receive {:set, _name, _value}
      assert MemoryStore.rows() == %{"stereo.cameras.exposure_us" => 5000}
    end

    @tag saved: %{"stereo.disparity.p1" => 10}
    test "a re-declared group gets its saved values back after its owner restarts",
         %{server: server} do
      {owner, _agent} = start_owner(server, &match_groups/1)
      assert_receive {:set, "p1", 10}
      stop_owner(owner)

      {_owner, agent} = start_owner(server, &match_groups/1)

      assert_receive {:set, "p1", 10}
      assert Agent.get(agent, & &1["p1"]) == 10
      assert {:ok, %{state: :saved}} = Parameters.get(server, "stereo.disparity.p1")
    end

    @tag saved: %{"stereo.disparity.p2" => 70, "stereo.cameras.exposure_us" => 5000}
    test "save stores changed values, drops values back at their default and saved automatic values",
         %{server: server} do
      start_owner(server, &match_groups/1)
      start_owner(server, &cameras_groups(&1, true))

      assert {:ok, _parameter} = Parameters.set(server, "stereo.disparity.p1", 12)
      assert {:ok, _parameter} = Parameters.set(server, "stereo.disparity.p2", 64)

      assert {:ok, ids} = Parameters.save(server)

      assert Enum.sort(ids) ==
               ["stereo.cameras.exposure_us", "stereo.disparity.p1", "stereo.disparity.p2"]

      assert MemoryStore.rows() == %{"stereo.disparity.p1" => 12}
      assert Parameters.unsaved_count(server) == 0
      assert {:ok, %{saved: 12, state: :saved}} = Parameters.get(server, "stereo.disparity.p1")
      assert Parameters.save(server) == {:ok, []}
    end

    test "save leaves out a parameter whose value cannot be read", %{server: server} do
      {_owner, agent} = start_owner(server, &match_groups/1)
      assert {:ok, _parameter} = Parameters.set(server, "stereo.disparity.p1", 12)
      Agent.update(agent, &Map.put(&1, "p1", nil))

      assert Parameters.save(server) == {:ok, []}
      assert MemoryStore.rows() == %{}
      assert Parameters.discard(server) == {:ok, []}
      assert Parameters.reset(server, :all) == {:ok, []}
      refute_receive {:set, _name, nil}
    end

    test "reset skips a parameter without a default", %{server: server} do
      unread_p1 = fn test ->
        {groups, agent} = match_groups(test)
        Agent.update(agent, &Map.put(&1, "p1", nil))
        {groups, agent}
      end

      {_owner, agent} = start_owner(server, unread_p1)
      Agent.update(agent, &Map.put(&1, "p1", 12))

      assert Parameters.reset(server, :all) == {:ok, []}
      assert Agent.get(agent, & &1["p1"]) == 12
    end

    @tag store: __MODULE__.FailingStore
    test "save answers the store's error and keeps the changes unsaved", %{server: server} do
      start_owner(server, &match_groups/1)
      assert {:ok, _parameter} = Parameters.set(server, "stereo.disparity.p1", 12)

      assert Parameters.save(server) == {:error, "saved parameters unavailable"}
      assert Parameters.unsaved_count(server) == 1
      assert {:ok, %{saved: nil, state: :unsaved}} = Parameters.get(server, "stereo.disparity.p1")
    end

    @tag saved: %{"stereo.disparity.p1" => 10}
    test "discard sets unsaved values back to their saved value, or their default",
         %{server: server} do
      {owner, agent} = start_owner(server, &match_groups/1)
      assert_receive {:set, "p1", 10}
      assert {:ok, _parameter} = Parameters.set(server, "stereo.disparity.p2", 70)
      assert {:ok, _parameter} = Parameters.set(server, "stereo.disparity.p1", 20)
      assert length(receive_sets(2)) == 2

      assert {:ok, ids} = Parameters.discard(server)
      assert Enum.sort(ids) == ["stereo.disparity.p1", "stereo.disparity.p2"]
      assert Agent.get(agent, & &1) == %{"p1" => 10, "p2" => 64}
      assert Parameters.unsaved_count(server) == 0
      assert length(receive_sets(2)) == 2

      stop_owner(owner)
      start_owner(server, &match_groups/1)
      assert_receive {:set, "p1", 10}
      refute_receive {:set, _name, _value}
    end

    test "discard and reset leave a parameter its automatic mode controls alone",
         %{server: server} do
      {_owner, agent} = start_owner(server, &cameras_groups(&1, true))
      Agent.update(agent, &%{&1 | "exposure_us" => 8000})

      assert Parameters.discard(server) == {:ok, []}
      assert Parameters.reset(server, :all) == {:ok, []}
      refute_receive {:set, _name, _value}
      assert Agent.get(agent, & &1["exposure_us"]) == 8000
    end

    @tag saved: %{"stereo.disparity.p1" => 10}
    test "reset sets a parameter, a group or everything to defaults, unsaved until saved",
         %{server: server} do
      {owner, _agent} = start_owner(server, &match_groups/1)
      start_owner(server, &preview_groups/1)

      assert Parameters.reset(server, {:parameter, "stereo.disparity.p1"}) ==
               {:ok, ["stereo.disparity.p1"]}

      assert {:ok, %{value: 8, saved: 10, state: :unsaved}} =
               Parameters.get(server, "stereo.disparity.p1")

      assert {:ok, _parameter} = Parameters.set(server, "stereo.disparity.p2", 70)
      assert {:ok, _parameter} = Parameters.set(server, "preview.quality", 55)

      assert Parameters.reset(server, {:group, "stereo.disparity"}) ==
               {:ok, ["stereo.disparity.p2"]}

      assert Parameters.reset(server, :all) == {:ok, ["preview.quality"]}
      assert Parameters.unsaved_count(server) == 1

      assert Parameters.reset(server, {:parameter, "stereo.disparity.p9"}) ==
               {:error, "unknown parameter"}

      assert Parameters.reset(server, {:group, "stereo.nothing"}) == {:error, "unknown group"}

      stop_owner(owner)
      {_owner, agent} = start_owner(server, &match_groups/1)
      assert Agent.get(agent, & &1["p1"]) == 8

      assert Parameters.save(server) == {:ok, ["stereo.disparity.p1"]}
      assert MemoryStore.rows() == %{}
    end

    @tag saved: %{"stereo.disparity.p1" => 10}
    test "forget deletes the saved value at once", %{server: server} do
      start_owner(server, &match_groups/1)

      assert Parameters.forget(server, "stereo.disparity.p1") == :ok
      assert MemoryStore.rows() == %{}

      assert {:ok, %{value: 10, saved: nil, state: :unsaved}} =
               Parameters.get(server, "stereo.disparity.p1")
    end

    @tag saved: %{
           "stereo.disparity.p1" => 10,
           "stereo.disparity.p2" => 70,
           "stereo.cameras.auto_exposure" => false,
           "detection.min_score" => 0.5
         }
    test "export renders the saved values with their composer paths", %{server: server} do
      start_owner(server, &match_groups/1)
      start_owner(server, &cameras_groups(&1, true))

      assert Parameters.export(server) == """
             # In the options of the stereo component ({:stereo, opts}):
             stages: VisionCore.Stereo.Pipeline.default_stages(disparity: [p1: 10, p2: 70])

             # Not settable in the composer:
             # stereo.cameras.auto_exposure = false

             # Saved for parameters not running now:
             # detection.min_score = 0.5
             """
    end

    @tag saved: %{"stereo.disparity.p1" => 10}
    test "export lists the saved values of a group whose owner is down as not running now",
         %{server: server} do
      {owner, _agent} = start_owner(server, &match_groups/1)
      stop_owner(owner)

      assert Parameters.export(server) == """
             # Saved for parameters not running now:
             # stereo.disparity.p1 = 10
             """
    end
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
      id: "stereo.disparity",
      name: "Disparity",
      summary: "Matches the rectified rows",
      kind: :stage,
      placement: :flow,
      position: 2,
      status: fn -> {:ok, "matching"} end,
      parameters: [
        backed(agent, test, "p1", :integer, %{kind: :range, min: 0, max: 78, step: nil})
        |> Map.put(:export, [:components, :stereo, :stages, :disparity, :p1]),
        backed(agent, test, "p2", :integer, %{kind: :range, min: 1, max: 79, step: nil})
        |> Map.merge(%{
          greater_than: "p1",
          export: [:components, :stereo, :stages, :disparity, :p2]
        })
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

  # A camera automatic while its exposure is 0, whose switch off does nothing: what it controls must be set.
  defp switch_only_groups(_test) do
    {:ok, exposure} = Agent.start_link(fn -> 0 end)

    group = %{
      id: "camera",
      name: "Camera",
      summary: "Captures",
      kind: :component,
      placement: :flow,
      position: 0,
      parameters: [
        %{
          name: "auto_exposure",
          type: :bool,
          constraint: %{kind: :bool},
          get: fn -> Agent.get(exposure, & &1) == 0 end,
          set: fn
            true -> Agent.update(exposure, fn _ -> 0 end)
            false -> :ok
          end
        },
        %{
          name: "exposure_us",
          type: :integer,
          constraint: %{kind: :range, min: 1, max: 1_000_000, step: nil},
          applies: {:auto, "camera.auto_exposure"},
          default: 10_000,
          get: fn -> with 0 <- Agent.get(exposure, & &1), do: 10_000 end,
          set: &Agent.update(exposure, fn _ -> &1 end)
        }
      ]
    }

    {[group], exposure}
  end

  defp preview_groups(test) do
    {:ok, agent} =
      Agent.start_link(fn -> %{"quality" => 80, "colormap" => "jet", "mode" => :auto} end)

    group = %{
      id: "preview",
      name: "Preview",
      summary: "Encodes the preview images",
      kind: :component,
      placement: :side,
      position: 5,
      parameters: [
        backed(agent, test, "quality", :integer, %{kind: :range, min: 10, max: 100, step: 5}),
        backed(agent, test, "colormap", :string, %{kind: :choices, values: ["jet", "gray"]}),
        backed(agent, test, "mode", :string, %{kind: :choices, values: [{:fixed, 2}, :auto, nil]})
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

  defp throwing_groups(_test) do
    group = %{
      id: "throwing",
      name: "Throwing",
      summary: "Throws",
      kind: :stage,
      placement: :side,
      position: 9,
      status: fn -> throw(:no_status) end,
      parameters: [
        %{
          name: "throws",
          type: :integer,
          constraint: %{kind: :range, min: 0, max: 10, step: nil},
          get: fn -> throw(:gone) end,
          set: fn _value -> throw(:busy) end
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
