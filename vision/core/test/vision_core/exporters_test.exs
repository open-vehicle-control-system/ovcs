defmodule VisionCore.ExportersTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias VisionCore.{Exporters, Outputs}
  alias VisionCore.Exporter.Runner

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

  defp config,
    do: %VisionCore.Config{
      zenoh_endpoint_ip: "127.0.0.1",
      components: [{:stereo, driver: Camera, left: [], right: []}]
    }

  defp exporter_pid(id) do
    {^id, pid, :supervisor, _modules} =
      Exporters |> Supervisor.which_children() |> List.keyfind(id, 0)

    pid
  end

  defp exporter_ids,
    do: for({id, _pid, :supervisor, _modules} <- Supervisor.which_children(Exporters), do: id)

  # Returns once the exporter's runner is done with its init/1, and so subscribed.
  defp await_runner(id) do
    {Runner, runner, :worker, _modules} =
      id |> exporter_pid() |> Supervisor.which_children() |> List.keyfind(Runner, 0)

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

  test "the configuration names no exporter" do
    assert Exporters.from_config(config()) == []

    start_supervised!({Exporters, config: config()})

    assert exporter_ids() == []
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
    await_runner(Steady)

    log = capture_log(fn -> produce_until_stopped(Crashing) end)
    Producer.produce(:producer, :last)

    assert_receive {:exported, :last}
    assert Process.whereis(:producer) == producer
    assert Process.whereis(Exporters) == exporters
    assert exporter_pid(Steady) == steady
    assert log =~ "#{inspect(Crashing)} stopped"
  end

  test "an orderly shutdown logs no exporter as stopped" do
    start_supervised!({Exporters, config: config(), exporters: [{Steady, test: self()}]})
    await_runner(Steady)

    log = capture_log(fn -> stop_supervised!(Exporters) end)

    refute log =~ "stopped"
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

  test "hands each exporter, in its options, the JPEG codec it encodes on" do
    start_supervised!(
      {Exporters,
       config: config(), jpeg_codec: :export_codec, exporters: [{Steady, test: self()}]}
    )

    assert_receive {:started, options}
    assert options[:jpeg_codec] == :export_codec
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
