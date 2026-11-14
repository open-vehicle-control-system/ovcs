defmodule VisionCore.ReviverTest do
  use ExUnit.Case, async: true

  alias VisionCore.Reviver

  # Tells the test each time it starts; `:ignore` while the test's flag says it cannot start.
  defmodule Unit do
    def child_spec(opts) do
      %{
        id: Keyword.fetch!(opts, :id),
        start: {__MODULE__, :start_link, [opts]},
        restart: :transient
      }
    end

    def start_link(opts) do
      send(opts[:test], {:started, opts[:id]})

      if :atomics.get(opts[:startable], 1) == 1,
        do: Agent.start_link(fn -> nil end),
        else: :ignore
    end
  end

  defp start_units(ids, startable \\ 1) do
    flag = :atomics.new(1, [])
    :atomics.put(flag, 1, startable)
    children = for id <- ids, do: {Unit, id: id, test: self(), startable: flag}

    supervisor =
      start_supervised!(%{
        id: :units,
        start: {Supervisor, :start_link, [children, [strategy: :rest_for_one]]}
      })

    for id <- ids, do: assert_receive({:started, ^id})
    {supervisor, flag}
  end

  defp eventually(check, attempts \\ 200) do
    cond do
      check.() -> :ok
      attempts == 0 -> flunk("condition never held")
      true -> Process.sleep(10) && eventually(check, attempts - 1)
    end
  end

  defp pid_of(supervisor, id) do
    {^id, pid, _type, _modules} = List.keyfind(Supervisor.which_children(supervisor), id, 0)
    pid
  end

  test "restarts a unit that stopped, leaving the running ones as they are" do
    {supervisor, _flag} = start_units([:camera, :detector])
    detector = pid_of(supervisor, :detector)
    :ok = Agent.stop(pid_of(supervisor, :camera))
    assert pid_of(supervisor, :camera) == :undefined

    start_supervised!(
      {Reviver, supervisor: supervisor, units: [:camera, :detector], interval_ms: 10, name: nil}
    )

    assert_receive {:started, :camera}, 2_000
    refute_received {:started, :detector}
    assert pid_of(supervisor, :detector) == detector
  end

  test "tries a unit that could not start again until it starts" do
    {supervisor, flag} = start_units([:camera], 0)
    assert pid_of(supervisor, :camera) == :undefined

    start_supervised!(
      {Reviver, supervisor: supervisor, units: [:camera], interval_ms: 10, name: nil}
    )

    assert_receive {:started, :camera}, 2_000
    :atomics.put(flag, 1, 1)
    eventually(fn -> is_pid(pid_of(supervisor, :camera)) end)
  end

  test "leaves alone a child that is none of its units" do
    {supervisor, _flag} = start_units([:camera, :other])
    :ok = Agent.stop(pid_of(supervisor, :other))

    start_supervised!(
      {Reviver, supervisor: supervisor, units: [:camera], interval_ms: 10, name: nil}
    )

    refute_receive {:started, :other}, 100
  end

  test "refuses an interval that is no positive integer" do
    assert {:error, {{%ArgumentError{message: message}, _stacktrace}, _child}} =
             start_supervised({Reviver, supervisor: self(), units: [], interval_ms: 0, name: nil})

    assert message =~ ":interval_ms"
  end
end
