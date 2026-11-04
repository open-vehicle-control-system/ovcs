defmodule VisionCore.ExportersTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias VisionCore.{Exporters, Outputs}
  alias VisionCore.Exporter.Runner
  alias VisionCore.Exporters.Watch

  @moduletag :capture_log
  @pairs {:stereo_pair, VisionCore.Stereo.Pipeline}

  # Names a stereo unit's cameras, which need not be running.
  defmodule Camera do
    def name_for(label), do: Module.concat(__MODULE__, label)
  end

  # Publishes pairs, as the stereo pipeline does.
  defmodule Producer do
    use GenServer

    def start_link(name), do: GenServer.start_link(__MODULE__, nil, name: name)
    def produce(name, pair), do: GenServer.call(name, {:produce, pair})

    @impl GenServer
    def init(nil), do: {:ok, nil}

    @impl GenServer
    def handle_call({:produce, pair}, _from, state) do
      :ok = Outputs.publish({:stereo_pair, VisionCore.Stereo.Pipeline}, {:stereo_pair, pair})
      {:reply, :ok, state}
    end
  end

  # Tells the test its options at start, then hands it each pair.
  defmodule Steady do
    @behaviour VisionCore.Exporter

    @impl VisionCore.Exporter
    def outputs(_options), do: [:stereo_pair]

    @impl VisionCore.Exporter
    def init(options) do
      test = Keyword.fetch!(options, :test)
      send(test, {:started, options})
      {:ok, test}
    end

    @impl VisionCore.Exporter
    def handle_output(:stereo_pair, pair, test) do
      send(test, {:exported, pair})
      {:ok, test}
    end
  end

  defmodule Crashing do
    @behaviour VisionCore.Exporter

    @impl VisionCore.Exporter
    def outputs(_options), do: [:stereo_pair]

    @impl VisionCore.Exporter
    def init(_options), do: {:ok, nil}

    @impl VisionCore.Exporter
    def handle_output(:stereo_pair, _pair, _state), do: raise("cannot export")
  end

  # Exports each pair but `:crash`, on which it crashes.
  defmodule CrashingOnce do
    @behaviour VisionCore.Exporter

    @impl VisionCore.Exporter
    def outputs(_options), do: [:stereo_pair]

    @impl VisionCore.Exporter
    def init(options), do: {:ok, Keyword.fetch!(options, :test)}

    @impl VisionCore.Exporter
    def handle_output(:stereo_pair, :crash, _test), do: raise("cannot export")

    def handle_output(:stereo_pair, pair, test) do
      send(test, {:exported, pair})
      {:ok, test}
    end
  end

  defmodule Misnamed do
    @behaviour VisionCore.Exporter

    @impl VisionCore.Exporter
    def outputs(_options), do: [:stereo_pairs]

    @impl VisionCore.Exporter
    def init(_options), do: {:ok, nil}

    @impl VisionCore.Exporter
    def handle_output(_output, _value, state), do: {:ok, state}
  end

  # Reads, from its init/1, the helper its children/1 starts.
  defmodule WithHelper do
    @behaviour VisionCore.Exporter

    @impl VisionCore.Exporter
    def children(_options),
      do: [%{id: :helper, start: {Agent, :start_link, [fn -> :ready end, [name: __MODULE__]]}}]

    @impl VisionCore.Exporter
    def outputs(_options), do: []

    @impl VisionCore.Exporter
    def init(_options), do: {:ok, Agent.get(__MODULE__, & &1)}

    @impl VisionCore.Exporter
    def handle_output(_output, _value, state), do: {:ok, state}
  end

  # Waits in its init/1 until the test lets it go.
  defmodule Blocking do
    @behaviour VisionCore.Exporter

    @impl VisionCore.Exporter
    def outputs(_options), do: [:stereo_pair]

    @impl VisionCore.Exporter
    def init(options) do
      test = Keyword.fetch!(options, :test)
      send(test, {:initialising, self()})
      receive do: (:go -> {:ok, test})
    end

    @impl VisionCore.Exporter
    def handle_output(:stereo_pair, pair, test) do
      send(test, {:blocking_exported, pair})
      {:ok, test}
    end
  end

  defmodule BrokenHelper do
    @behaviour VisionCore.Exporter

    @impl VisionCore.Exporter
    def children(_options),
      do: [%{id: :helper, start: {Kernel, :apply, [fn -> {:error, :no_device} end, []]}}]

    @impl VisionCore.Exporter
    def outputs(_options), do: []

    @impl VisionCore.Exporter
    def init(_options), do: {:ok, nil}

    @impl VisionCore.Exporter
    def handle_output(_output, _value, state), do: {:ok, state}
  end

  # Listed under an id and a name of its own.
  defmodule Described do
    @behaviour VisionCore.Exporter

    @impl VisionCore.Exporter
    def describe(_options), do: %{id: :described, name: "Described"}

    @impl VisionCore.Exporter
    def outputs(_options), do: [{:camera_frame, :left}, stereo_pair: [max_hz: 5]]

    @impl VisionCore.Exporter
    def init(_options), do: {:ok, nil}

    @impl VisionCore.Exporter
    def handle_output(_output, _value, state), do: {:ok, state}

    @impl VisionCore.Exporter
    def status(_state), do: {:ok, "Connected"}
  end

  # Refuses to run, for want of what its options name.
  defmodule Refusing do
    @behaviour VisionCore.Exporter

    @impl VisionCore.Exporter
    def check(_options), do: {:error, "no broker to publish to"}

    @impl VisionCore.Exporter
    def outputs(_options), do: [:stereo_pair]

    @impl VisionCore.Exporter
    def init(_options), do: {:ok, nil}

    @impl VisionCore.Exporter
    def handle_output(_output, _value, state), do: {:ok, state}
  end

  defmodule RaisingCheck do
    @behaviour VisionCore.Exporter

    @impl VisionCore.Exporter
    def check(options), do: Keyword.fetch!(options, :broker)

    @impl VisionCore.Exporter
    def outputs(_options), do: []

    @impl VisionCore.Exporter
    def init(_options), do: {:ok, nil}

    @impl VisionCore.Exporter
    def handle_output(_output, _value, state), do: {:ok, state}
  end

  # Reads the pairs and the detections, which the test configuration has no detector for.
  defmodule Detecting do
    @behaviour VisionCore.Exporter

    @impl VisionCore.Exporter
    def outputs(_options), do: [:stereo_pair, detections: [max_hz: 2]]

    @impl VisionCore.Exporter
    def init(_options), do: {:ok, nil}

    @impl VisionCore.Exporter
    def handle_output(_output, _value, state), do: {:ok, state}
  end

  # Answers its status a second late.
  defmodule Stuck do
    @behaviour VisionCore.Exporter

    @impl VisionCore.Exporter
    def describe(options), do: %{id: Keyword.fetch!(options, :stuck_id), name: "Stuck"}

    @impl VisionCore.Exporter
    def outputs(_options), do: []

    @impl VisionCore.Exporter
    def init(_options), do: {:ok, nil}

    @impl VisionCore.Exporter
    def handle_output(_output, _value, state), do: {:ok, state}

    @impl VisionCore.Exporter
    def status(_state) do
      Process.sleep(1_000)
      {:ok, "Late"}
    end
  end

  # Answers `ping` at once, and `stall` never.
  defmodule Acting do
    @behaviour VisionCore.Exporter

    @impl VisionCore.Exporter
    def describe(_options), do: %{id: :acting, name: "Acting"}

    @impl VisionCore.Exporter
    def outputs(_options), do: []

    @impl VisionCore.Exporter
    def actions(_options),
      do: [
        %{name: :ping, label: "Ping", description: "Answers at once."},
        %{name: :stall, label: "Stall", description: "Never answers."}
      ]

    @impl VisionCore.Exporter
    def init(options), do: {:ok, Keyword.fetch!(options, :test)}

    @impl VisionCore.Exporter
    def handle_output(_output, _value, test), do: {:ok, test}

    @impl VisionCore.Exporter
    def handle_action(:ping, _params, _from, test), do: {:reply, {:ok, %{pong: true}}, test}

    def handle_action(:stall, _params, _from, test) do
      send(test, :stalled)
      {:noreply, test}
    end
  end

  defp config(exporters \\ []),
    do: %VisionCore.Config{
      components: [{:stereo, driver: Camera, left: [], right: []}],
      exporters: exporters
    }

  defp exporter_pid(id) do
    {^id, pid, :supervisor, _modules} =
      Exporters |> Supervisor.which_children() |> List.keyfind(id, 0)

    pid
  end

  defp exporter_ids,
    do: for({id, _pid, :supervisor, _modules} <- Supervisor.which_children(Exporters), do: id)

  defp runner_pid(id) do
    {Runner, runner, :worker, _modules} =
      id |> exporter_pid() |> Supervisor.which_children() |> List.keyfind(Runner, 0)

    runner
  end

  # Returns once the exporter's runner is done with its init/1, and so subscribed.
  defp await_runner(id) do
    runner = runner_pid(id)
    :sys.get_state(runner)
    runner
  end

  defp produce_until_stopped(id, attempts \\ 300) do
    cond do
      exporter_pid(id) == :undefined ->
        :ok

      attempts > 0 ->
        Producer.produce(:producer, :pair)
        Process.sleep(10)
        produce_until_stopped(id, attempts - 1)

      true ->
        flunk("#{inspect(id)} kept running")
    end
  end

  # The watcher's monitor of `pid` is gone once the :DOWN is in its mailbox, so :sys.get_state/1
  # then returns after the watcher has handled it.
  defp sync_watch(pid) do
    eventually(fn -> not watching?(pid) end)
    :sys.get_state(watch())
    :ok
  end

  defp watching?(pid) do
    {:monitors, monitors} = Process.info(watch(), :monitors)
    {:process, pid} in monitors
  end

  defp watch do
    {Watch, watch, :worker, _modules} =
      Exporters |> Supervisor.which_children() |> List.keyfind(Watch, 0)

    watch
  end

  defp eventually(check, attempts \\ 200) do
    cond do
      check.() -> :ok
      attempts == 0 -> flunk("condition not met")
      true -> Process.sleep(10) && eventually(check, attempts - 1)
    end
  end

  test "runs the exporters of its configuration without :exporters" do
    start_supervised!({Exporters, config: config([{Steady, test: self()}])})

    assert exporter_ids() == [Steady]
    assert_receive {:started, _options}
  end

  describe "list/1" do
    test "lists each exporter in the configuration's order: its id, name, module, status and outputs" do
      start_supervised!(
        {Exporters, config: config(), exporters: [{Described, []}, {Steady, test: self()}]}
      )

      await_runner(:described)
      await_runner(Steady)

      assert Exporters.list() == [
               %{
                 id: "described",
                 name: "Described",
                 module: Described,
                 status: {:ok, "Connected"},
                 outputs: [
                   %{output: {:camera_frame, :left}, max_hz: nil},
                   %{output: :stereo_pair, max_hz: 5}
                 ],
                 actions: []
               },
               %{
                 id: "VisionCore.ExportersTest.Steady",
                 name: "VisionCore.ExportersTest.Steady",
                 module: Steady,
                 status: {:ok, "Running"},
                 outputs: [%{output: :stereo_pair, max_hz: nil}],
                 actions: []
               }
             ]
    end

    test "lists the actions each exporter declares" do
      start_supervised!({Exporters, config: config(), exporters: [{Acting, test: self()}]})

      assert [%{id: "acting", actions: actions}] = Exporters.list()
      assert Enum.map(actions, & &1.name) == [:ping, :stall]
    end

    test "lists the outputs the configuration produces, as the runner reads them" do
      start_supervised!({Exporters, config: config(), exporters: [{Detecting, []}]})

      assert [%{outputs: [%{output: :stereo_pair, max_hz: nil}]}] = Exporters.list()
    end

    test "an :id among an exporter's options replaces its own" do
      start_supervised!({Exporters, config: config(), exporters: [{Described, id: :front}]})

      assert exporter_ids() == [:front]
      assert [%{id: "front", name: "Described"}] = Exporters.list()
    end

    test "lists an exporter that is not running as off, saying why" do
      capture_log(fn ->
        start_supervised!(
          {Exporters,
           config: config(), exporters: [{Refusing, []}, {Misnamed, []}, {Steady, test: self()}]}
        )
      end)

      await_runner(Steady)
      :ok = Supervisor.terminate_child(Exporters, Steady)

      assert [
               %{status: {:off, "Not started: no broker to publish to"}},
               %{status: {:off, "Not started: " <> misnamed}},
               %{status: {:off, "Not running"}}
             ] = Exporters.list()

      assert misnamed =~ ":stereo_pairs"
    end

    @tag timeout: 10_000
    test "asks the statuses at once, reporting one that misses the deadline as not answering" do
      start_supervised!(
        {Exporters,
         config: config(),
         exporters: [{Stuck, stuck_id: :first}, {Stuck, stuck_id: :second}, {Described, []}]}
      )

      for id <- [:first, :second, :described], do: await_runner(id)

      {elapsed_us, listed} = :timer.tc(fn -> Exporters.list(100) end)

      assert [
               %{id: "first", status: {:warning, "Not answering"}},
               %{id: "second", status: {:warning, "Not answering"}},
               %{id: "described", status: {:ok, "Connected"}}
             ] = listed

      assert elapsed_us < 180_000
    end

    test "is empty while the exporters are not running" do
      assert Exporters.list() == []
    end
  end

  describe "action/4" do
    test "runs an action of the exporter its id names" do
      start_supervised!({Exporters, config: config(), exporters: [{Acting, test: self()}]})
      await_runner(:acting)

      assert Exporters.action("acting", "ping", %{}, 1000) == {:ok, %{pong: true}}
      assert Exporters.action("acting", "pong", %{}, 1000) == {:error, :unknown_action}
    end

    test "an id no exporter has is not found" do
      start_supervised!({Exporters, config: config(), exporters: [{Acting, test: self()}]})

      assert Exporters.action("unknown", "ping", %{}, 1000) == {:error, :not_found}
    end

    test "an action that does not answer within the timeout times out" do
      start_supervised!({Exporters, config: config(), exporters: [{Acting, test: self()}]})
      await_runner(:acting)

      assert {:error, {:timeout, message}} = Exporters.action("acting", "stall", %{}, 50)
      assert message =~ "50 ms"
    end

    test "an exporter that is not running, or whose runner stops before answering, is not running" do
      start_supervised!({Exporters, config: config(), exporters: [{Acting, test: self()}]})
      runner = await_runner(:acting)

      task = Task.async(fn -> Exporters.action("acting", "stall", %{}, 1000) end)
      assert_receive :stalled
      Process.exit(runner, :kill)

      assert Task.await(task) == {:error, :not_running}

      :ok = Supervisor.terminate_child(Exporters, :acting)

      assert Exporters.action("acting", "ping", %{}, 1000) == {:error, :not_running}
    end
  end

  test "an exporter that refuses its options is not started, with its reason logged, and the others start" do
    log =
      capture_log(fn ->
        start_supervised!(
          {Exporters, config: config(), exporters: [{Refusing, []}, {Steady, test: self()}]}
        )
      end)

    assert exporter_pid(Refusing) == :undefined
    assert_receive {:started, _options}
    assert log =~ "#{inspect(Refusing)} not started: no broker to publish to"
  end

  test "an exporter whose check raises is not started, and the others start" do
    log =
      capture_log(fn ->
        start_supervised!(
          {Exporters, config: config(), exporters: [{RaisingCheck, []}, {Steady, test: self()}]}
        )
      end)

    assert exporter_pid(RaisingCheck) == :undefined
    assert_receive {:started, _options}
    assert log =~ "#{inspect(RaisingCheck)} not started"
    assert log =~ ":broker"
  end

  test "an entry that is not a module or {module, options} is left out, logged, and the others start" do
    log =
      capture_log(fn ->
        start_supervised!(
          {Exporters,
           config: config(), exporters: [{Steady, :fast}, "Steady", {Steady, test: self()}]}
        )
      end)

    assert exporter_ids() == [Steady]
    assert_receive {:started, _options}
    assert log =~ "not an exporter"
  end

  test "runs a module alone as an exporter without options" do
    start_supervised!({Exporters, config: config(), exporters: [Described]})

    assert exporter_ids() == [:described]
  end

  test "an exporter that keeps crashing stops alone: the producer and the other exporters run on" do
    # As in VisionCore.Supervisor: producers first, the exporters last, under its default budget.
    start_supervised!(%{
      id: :unit,
      type: :supervisor,
      start:
        {Supervisor, :start_link,
         [
           [
             {Producer, :producer},
             {Exporters, config: config(), exporters: [{Crashing, []}, {Steady, test: self()}]}
           ],
           [strategy: :rest_for_one]
         ]}
    })

    producer = Process.whereis(:producer)
    exporters = Process.whereis(Exporters)
    steady = exporter_pid(Steady)
    crashing = exporter_pid(Crashing)
    await_runner(Steady)

    log =
      capture_log(fn ->
        produce_until_stopped(Crashing)
        sync_watch(crashing)
      end)

    Producer.produce(:producer, :last)

    assert_receive {:exported, :last}
    assert Process.whereis(:producer) == producer
    assert Process.whereis(Exporters) == exporters
    assert exporter_pid(Steady) == steady
    assert log =~ "#{inspect(Crashing)} stopped"

    assert [%{status: {:off, "Stopped: it kept failing"}}, %{status: {:ok, _running}}] =
             Exporters.list()
  end

  test "an orderly shutdown logs no exporter as stopped" do
    start_supervised!({Exporters, config: config(), exporters: [{Steady, test: self()}]})
    await_runner(Steady)

    log = capture_log(fn -> stop_supervised!(Exporters) end)

    refute log =~ "stopped"
  end

  test "an exporter stopped on purpose is not logged as one that kept failing" do
    start_supervised!({Exporters, config: config(), exporters: [{Steady, test: self()}]})
    await_runner(Steady)
    steady = exporter_pid(Steady)
    eventually(fn -> watching?(steady) end)

    log =
      capture_log(fn ->
        :ok = Supervisor.terminate_child(Exporters, Steady)
        sync_watch(steady)
      end)

    refute log =~ "kept failing"
  end

  test "an exporter that crashed and started again is not logged as failing when stopped on purpose" do
    start_supervised!({Exporters, config: config(), exporters: [{CrashingOnce, test: self()}]})
    runner = await_runner(CrashingOnce)

    Outputs.publish(@pairs, {:stereo_pair, :crash})
    eventually(fn -> is_pid(runner_pid(CrashingOnce)) and runner_pid(CrashingOnce) != runner end)
    restarted = await_runner(CrashingOnce)
    sync_watch(runner)
    eventually(fn -> watching?(restarted) end)
    Outputs.publish(@pairs, {:stereo_pair, :pair})
    assert_receive {:exported, :pair}
    exporter = exporter_pid(CrashingOnce)

    log =
      capture_log(fn ->
        :ok = Supervisor.terminate_child(Exporters, CrashingOnce)
        sync_watch(exporter)
      end)

    refute log =~ "kept failing"
  end

  test "a second exporter under an id already taken is left out, logged, and the others start" do
    log =
      capture_log(fn ->
        start_supervised!(
          {Exporters,
           config: config(),
           exporters: [
             {Steady, test: self(), copy: :first},
             {Steady, test: self(), copy: :second}
           ]}
        )
      end)

    assert exporter_ids() == [Steady]
    assert_receive {:started, options}
    assert options[:copy] == :first
    refute_receive {:started, _options}, 100
    assert log =~ "#{inspect(Steady)}"
  end

  @tag timeout: 10_000
  test "an exporter whose init/1 takes its time holds up neither the start nor the other exporters" do
    start_supervised!(
      {Exporters, config: config(), exporters: [{Blocking, test: self()}, {Steady, test: self()}]}
    )

    assert_receive {:initialising, blocking}
    await_runner(Steady)
    Outputs.publish(@pairs, {:stereo_pair, :first})
    assert_receive {:exported, :first}

    send(blocking, :go)
    await_runner(Blocking)
    Outputs.publish(@pairs, {:stereo_pair, :second})

    assert_receive {:blocking_exported, :second}
    assert_receive {:exported, :second}
  end

  test "an exporter that fails to start is left down, and the others start" do
    log =
      capture_log(fn ->
        start_supervised!(
          {Exporters, config: config(), exporters: [{Misnamed, []}, {Steady, test: self()}]}
        )
      end)

    assert exporter_pid(Misnamed) == :undefined
    assert is_pid(exporter_pid(Steady))
    assert log =~ "failed to start"
  end

  test "an exporter whose helper fails to start is left down, and the others start" do
    log =
      capture_log(fn ->
        start_supervised!(
          {Exporters, config: config(), exporters: [{BrokenHelper, []}, {Steady, test: self()}]}
        )
      end)

    assert exporter_pid(BrokenHelper) == :undefined
    assert is_pid(exporter_pid(Steady))
    assert log =~ "no_device"
  end

  test "registers an exporter's runner under the :name in its options" do
    start_supervised!(
      {Exporters, config: config(), exporters: [{Steady, name: :steady_runner, test: self()}]}
    )

    assert {Runner, runner, :worker, _modules} =
             Steady |> exporter_pid() |> Supervisor.which_children() |> List.keyfind(Runner, 0)

    assert Process.whereis(:steady_runner) == runner
  end

  test "starts an exporter's children/1 under its own supervisor, before its runner" do
    start_supervised!({Exporters, config: config(), exporters: [{WithHelper, []}]})

    assert [{Runner, runner, :worker, _}, {:helper, helper, :worker, _}] =
             Supervisor.which_children(exporter_pid(WithHelper))

    Process.exit(helper, :kill)

    assert eventually_restarted(WithHelper, Runner, runner)
  end

  test "hands each exporter, in its options, the JPEG codec it encodes on and the configuration" do
    start_supervised!(
      {Exporters,
       config: config(), jpeg_codec: :export_codec, exporters: [{Steady, test: self()}]}
    )

    assert_receive {:started, options}
    assert options[:jpeg_codec] == :export_codec
    assert options[:config] == config()
  end

  test "runs two instances of one exporter apart, by their :id" do
    start_supervised!(
      {Exporters,
       config: config(),
       exporters: [{Steady, id: :first, test: self()}, {Steady, id: :second, test: self()}]}
    )

    await_runner(:first)
    await_runner(:second)
    Outputs.publish(@pairs, {:stereo_pair, :pair})

    assert_receive {:exported, :pair}
    assert_receive {:exported, :pair}
  end

  defp eventually_restarted(exporter, child, old_pid, attempts \\ 100) do
    {^child, pid, :worker, _modules} =
      exporter |> exporter_pid() |> Supervisor.which_children() |> List.keyfind(child, 0)

    cond do
      is_pid(pid) and pid != old_pid ->
        true

      attempts > 0 ->
        Process.sleep(10) && eventually_restarted(exporter, child, old_pid, attempts - 1)

      true ->
        false
    end
  end
end
