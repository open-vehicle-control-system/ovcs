defmodule VisionCore.Exporter.RunnerTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias VisionCore.Camera.Frame
  alias VisionCore.Exporter.Runner
  alias VisionCore.Outputs

  @moduletag :capture_log
  @pairs {:stereo_pair, VisionCore.Stereo.Pipeline}

  # Names a stereo unit's cameras, which need not be running.
  defmodule Camera do
    def name_for(label), do: Module.concat(__MODULE__, label)
  end

  # Hands the test each value and when it was handed over. The value its `:block_on` option
  # names waits for `:release` first; those in `:reject` are not exported.
  defmodule Forwarder do
    @behaviour VisionCore.Exporter

    @impl VisionCore.Exporter
    def outputs(options), do: Keyword.fetch!(options, :outputs)

    @impl VisionCore.Exporter
    def init(options), do: {:ok, Map.new(options)}

    @impl VisionCore.Exporter
    def handle_output(output, value, state) do
      send(state.test, {:exported, output, value, System.monotonic_time(:millisecond)})

      if Map.has_key?(state, :block_on) and value == state.block_on,
        do: receive(do: (:release -> :ok))

      if value in Map.get(state, :reject, []),
        do: {:error, :rejected, state},
        else: {:ok, state}
    end
  end

  # Counts the pairs it is handed, which its status reports, and ticks on a timer of its own.
  defmodule Counter do
    @behaviour VisionCore.Exporter

    @impl VisionCore.Exporter
    def outputs(_options), do: [:stereo_pair]

    @impl VisionCore.Exporter
    def init(options) do
      Process.send_after(self(), :tick, 10)
      {:ok, %{test: Keyword.fetch!(options, :test), pairs: 0}}
    end

    @impl VisionCore.Exporter
    def handle_output(:stereo_pair, _pair, state), do: {:ok, %{state | pairs: state.pairs + 1}}

    @impl VisionCore.Exporter
    def status(state), do: {:ok, "#{state.pairs} pairs"}

    @impl VisionCore.Exporter
    def handle_info(:tick, state) do
      send(state.test, :ticked)
      {:ok, state}
    end
  end

  # Sends each pair on, as a slow transport would, and takes the next once told it is sent.
  defmodule Slow do
    @behaviour VisionCore.Exporter

    @impl VisionCore.Exporter
    def outputs(_options), do: [:stereo_pair]

    @impl VisionCore.Exporter
    def init(options), do: {:ok, Keyword.fetch!(options, :test)}

    @impl VisionCore.Exporter
    def handle_output(:stereo_pair, pair, test) do
      send(test, {:exported, :stereo_pair, pair})
      {:busy, test}
    end

    @impl VisionCore.Exporter
    def handle_info(:sent, test), do: {:ready, :stereo_pair, test}
  end

  # Busy with each output until told both are sent; the slot of its pairs opens five times a second.
  defmodule SlowPair do
    @behaviour VisionCore.Exporter

    @impl VisionCore.Exporter
    def outputs(_options), do: [stereo_pair: [max_hz: 5], detections: []]

    @impl VisionCore.Exporter
    def init(options), do: {:ok, Keyword.fetch!(options, :test)}

    @impl VisionCore.Exporter
    def handle_output(output, value, test) do
      send(test, {:exported, output, value, System.monotonic_time(:millisecond)})
      {:busy, test}
    end

    @impl VisionCore.Exporter
    def handle_info(:sent, test), do: {:ready, [:stereo_pair, :detections], test}
  end

  # Tells the test each time its init/1 runs.
  defmodule Announcing do
    @behaviour VisionCore.Exporter

    @impl VisionCore.Exporter
    def outputs(_options), do: [:stereo_pair]

    @impl VisionCore.Exporter
    def init(options) do
      test = Keyword.fetch!(options, :test)
      send(test, {:initialised, self()})
      {:ok, test}
    end

    @impl VisionCore.Exporter
    def handle_output(_output, _value, test), do: {:ok, test}
  end

  # Exports no value, each for a reason of its own, and has no status to give.
  defmodule Refusing do
    @behaviour VisionCore.Exporter

    @impl VisionCore.Exporter
    def outputs(_options), do: [:stereo_pair]

    @impl VisionCore.Exporter
    def init(options), do: {:ok, Keyword.fetch!(options, :test)}

    @impl VisionCore.Exporter
    def handle_output(:stereo_pair, pair, test) do
      send(test, {:exported, :stereo_pair, pair})
      {:error, {:refused, pair}, test}
    end

    @impl VisionCore.Exporter
    def status(_test), do: raise("no link")
  end

  defmodule FailingStatus do
    @behaviour VisionCore.Exporter

    @impl VisionCore.Exporter
    def outputs(_options), do: [:stereo_pair]

    @impl VisionCore.Exporter
    def init(options), do: {:ok, Keyword.fetch!(options, :test)}

    @impl VisionCore.Exporter
    def handle_output(:stereo_pair, pair, test) do
      send(test, {:exported, :stereo_pair, pair})
      {:ok, test}
    end

    @impl VisionCore.Exporter
    def status(_test), do: raise("no link")
  end

  # Gives as its status whatever its `:status` option holds.
  defmodule GivenStatus do
    @behaviour VisionCore.Exporter

    @impl VisionCore.Exporter
    def outputs(_options), do: []

    @impl VisionCore.Exporter
    def init(options), do: {:ok, Keyword.fetch!(options, :status)}

    @impl VisionCore.Exporter
    def handle_output(_output, _value, status), do: {:ok, status}

    @impl VisionCore.Exporter
    def status(status), do: status
  end

  # Starts on its attempt after the ones its `:attempts` agent scripts as failures.
  defmodule LateStart do
    @behaviour VisionCore.Exporter

    @impl VisionCore.Exporter
    def outputs(_options), do: [:stereo_pair]

    @impl VisionCore.Exporter
    def init(options) do
      case Agent.get_and_update(Keyword.fetch!(options, :attempts), &Enum.split(&1, 1)) do
        [:raise] -> raise "the recordings directory is missing"
        [{:error, reason}] -> {:error, reason}
        [] -> {:ok, Keyword.fetch!(options, :test)}
      end
    end

    @impl VisionCore.Exporter
    def handle_output(:stereo_pair, pair, test) do
      send(test, {:exported, :stereo_pair, pair})
      {:ok, test}
    end
  end

  defmodule Closing do
    @behaviour VisionCore.Exporter

    @impl VisionCore.Exporter
    def outputs(_options), do: [:stereo_pair]

    @impl VisionCore.Exporter
    def init(options), do: {:ok, Keyword.fetch!(options, :test)}

    @impl VisionCore.Exporter
    def handle_output(_output, _value, test), do: {:ok, test}

    @impl VisionCore.Exporter
    def terminate(reason, test), do: send(test, {:terminated, reason})
  end

  # Answers `ping` at once, and `later` once the runner is sent `:finish`; `raise` raises and
  # `malformed` answers no result. Its `:init` option replaces what its init/1 returns.
  defmodule Acting do
    @behaviour VisionCore.Exporter

    @impl VisionCore.Exporter
    def outputs(_options), do: []

    @impl VisionCore.Exporter
    def actions(_options),
      do: [
        %{name: :ping, label: "Ping", description: "Answers at once."},
        %{name: :later, label: "Later", description: "Answers once told to finish."},
        %{name: :raise, label: "Raise", description: "Raises."},
        %{name: :malformed, label: "Malformed", description: "Answers no result."}
      ]

    @impl VisionCore.Exporter
    def init(options),
      do: Keyword.get(options, :init, {:ok, %{test: Keyword.fetch!(options, :test), from: nil}})

    @impl VisionCore.Exporter
    def handle_output(_output, _value, state), do: {:ok, state}

    @impl VisionCore.Exporter
    def handle_action(:ping, _params, _from, state), do: {:reply, {:ok, %{pong: true}}, state}

    def handle_action(:later, _params, from, state) do
      send(state.test, :pending)
      {:noreply, %{state | from: from}}
    end

    def handle_action(:raise, _params, _from, _state), do: raise("boom")
    def handle_action(:malformed, _params, _from, state), do: {:ok, %{state | from: nil}}

    @impl VisionCore.Exporter
    def handle_info(:finish, state) do
      :ok = VisionCore.Exporter.reply(state.from, {:ok, %{done: true}})
      {:ok, %{state | from: nil}}
    end
  end

  defp config(components \\ [{:stereo, driver: Camera, left: [], right: []}, :detector]),
    do: %VisionCore.Config{components: components}

  # Started, and done with its exporter's init/1, which runs after the runner's own.
  defp start_runner(exporter, options, id \\ Runner, config \\ config()) do
    runner =
      start_supervised!(
        Supervisor.child_spec(
          {Runner, exporter: exporter, options: [test: self()] ++ options, config: config},
          id: id
        )
      )

    :sys.get_state(runner)
    runner
  end

  defp start_forwarder(options, config \\ config()),
    do: start_runner(Forwarder, options, Runner, config)

  defp publish_pair(pair), do: Outputs.publish(@pairs, {:stereo_pair, pair})

  defp publish_detections(pair),
    do:
      Outputs.publish(
        {:detections, VisionCore.Detection.Pipeline},
        {:detections, pair, []}
      )

  defp publish_frame(%Frame{label: label} = frame),
    do: Outputs.publish({:camera_frame, Camera.name_for(label)}, {:camera_frame, frame})

  defp frame(label, capture_ns),
    do: %Frame{label: label, width: 2, height: 2, capture_ns: capture_ns, jpeg: <<>>}

  defp eventually(check, attempts \\ 200) do
    cond do
      check.() -> :ok
      attempts == 0 -> flunk("condition not met")
      true -> Process.sleep(10) && eventually(check, attempts - 1)
    end
  end

  describe "outputs" do
    test "hands the exporter what the configuration's producers publish, by the outputs it names" do
      start_forwarder(
        outputs: [:stereo_pair, :detections, {:camera_frame, :left}, {:camera_frame, :right}]
      )

      left = frame("left", 1)
      right = frame("right", 1)

      publish_pair(:pair)

      Outputs.publish(
        {:detections, VisionCore.Detection.Pipeline},
        {:detections, :pair, [:person]}
      )

      publish_frame(left)
      publish_frame(right)

      assert_receive {:exported, :stereo_pair, :pair, _at}
      assert_receive {:exported, :detections, {:pair, [:person]}, _at}
      assert_receive {:exported, {:camera_frame, :left}, ^left, _at}
      assert_receive {:exported, {:camera_frame, :right}, ^right, _at}
    end

    test "names only the outputs it asks for" do
      start_forwarder(outputs: [{:camera_frame, :right}])

      publish_pair(:pair)
      publish_frame(frame("left", 1))
      publish_frame(frame("right", 2))

      assert_receive {:exported, {:camera_frame, :right}, %Frame{capture_ns: 2}, _at}
      refute_receive {:exported, _output, _value, _at}, 100
    end

    test "hands the exporter a named camera's frames apart from the stereo pair's" do
      config =
        config([
          {:stereo, driver: Camera, left: [], right: []},
          {:camera, name: :hq, driver: Camera}
        ])

      start_forwarder([outputs: [{:camera_frame, :hq}, {:camera_frame, :left}]], config)

      hq = frame("hq", 1)
      left = frame("left", 2)
      publish_frame(hq)
      publish_frame(left)

      assert_receive {:exported, {:camera_frame, :hq}, ^hq, _at}
      assert_receive {:exported, {:camera_frame, :left}, ^left, _at}
    end

    test "leaves out an output the configuration has no producer of" do
      runner = start_forwarder([outputs: [:stereo_pair, {:camera_frame, :left}]], config([]))

      refute runner in Outputs.subscribers(@pairs)
    end

    test "refuses to start on an output it does not know, or an option an output does not take" do
      for outputs <- [
            [:stereo_pairs],
            [{:camera_frame, :"front-cam"}],
            [stereo_pair: [rate: 5]],
            [stereo_pair: [max_hz: 0]],
            [:stereo_pair, stereo_pair: [max_hz: 5]]
          ] do
        assert {:error, {{:invalid_output, _output}, _child}} =
                 start_supervised(
                   {Runner,
                    exporter: Forwarder,
                    options: [test: self(), outputs: outputs],
                    config: config()}
                 )
      end
    end
  end

  describe "named detection pipelines" do
    @detection_outputs [:detections, {:detections, :road}, {:detections, :signs}]

    defp detectors_config,
      do: config([:detector, {:detector, name: :road}, {:detector, name: :signs}])

    defp publish_named_detections(name, pair, detections),
      do:
        Outputs.publish(
          {:detections, VisionCore.Detection.server(VisionCore.Detection.Pipeline, name)},
          {:detections, pair, detections, name}
        )

    test "hands each pipeline's detections to its own output only" do
      start_forwarder([outputs: @detection_outputs], detectors_config())

      publish_named_detections(:road, :road_pair, [:lane])
      assert_receive {:exported, {:detections, :road}, {:road_pair, [:lane]}, _at}
      refute_receive {:exported, _output, _value, _at}, 50

      Outputs.publish(
        {:detections, VisionCore.Detection.Pipeline},
        {:detections, :pair, [:person]}
      )

      assert_receive {:exported, :detections, {:pair, [:person]}, _at}
      refute_receive {:exported, _output, _value, _at}, 50

      publish_named_detections(:signs, :signs_pair, [:stop])
      assert_receive {:exported, {:detections, :signs}, {:signs_pair, [:stop]}, _at}
      refute_receive {:exported, _output, _value, _at}, 50
    end

    test "a busy exporter is handed each pipeline's newest detections, none taken for another's" do
      runner =
        start_forwarder([outputs: @detection_outputs, block_on: {0, []}], detectors_config())

      publish_detections(0)
      assert_receive {:exported, :detections, {0, []}, _at}

      for index <- 1..3 do
        publish_named_detections(:road, {:road, index}, [])
        publish_detections(index)
        publish_named_detections(:signs, {:signs, index}, [])
      end

      publish_named_detections(:road, {:road, 4}, [])
      send(runner, :release)

      assert_receive {:exported, :detections, {3, []}, _at}
      assert_receive {:exported, {:detections, :road}, {{:road, 4}, []}, _at}
      assert_receive {:exported, {:detections, :signs}, {{:signs, 3}, []}, _at}
      refute_receive {:exported, _output, _value, _at}, 100
    end
  end

  describe "flow control" do
    test "a busy exporter is handed the newest value of each output, the older ones dropped" do
      runner =
        start_forwarder(
          outputs: [:stereo_pair, {:camera_frame, :left}, {:camera_frame, :right}],
          block_on: 0
        )

      publish_pair(0)
      assert_receive {:exported, :stereo_pair, 0, _at}

      for pair <- 1..3, do: publish_pair(pair)

      for capture_ns <- 1..2,
          label <- ["left", "right"],
          do: publish_frame(frame(label, capture_ns))

      send(runner, :release)

      assert_receive {:exported, :stereo_pair, 3, _at}
      assert_receive {:exported, {:camera_frame, :left}, %Frame{capture_ns: 2}, _at}
      assert_receive {:exported, {:camera_frame, :right}, %Frame{capture_ns: 2}, _at}
      refute_receive {:exported, _output, _value, _at}, 100
    end

    test "hands an output at most :max_hz times a second, the latest held until its slot opens" do
      start_forwarder(outputs: [stereo_pair: [max_hz: 5]])

      publish_pair(1)
      assert_receive {:exported, :stereo_pair, 1, first_ms}
      publish_pair(2)
      publish_pair(3)

      assert_receive {:exported, :stereo_pair, 3, third_ms}, 1_000

      # Whole milliseconds, each read just after the runner's own reading: a tick may fall between.
      assert third_ms - first_ms >= 200 - 1
      refute_received {:exported, :stereo_pair, 2, _at}
      refute_receive {:exported, :stereo_pair, _pair, _at}, 300
    end

    test "when a held value's slot opens, a newer value of its output waiting then is handed instead" do
      runner = start_forwarder(outputs: [stereo_pair: [max_hz: 5]])
      publish_pair(1)
      assert_receive {:exported, :stereo_pair, 1, _at}
      publish_pair(2)
      :sys.get_state(runner)

      # The slot's timer lands in the suspended runner's mailbox, ahead of pair 3.
      :ok = :sys.suspend(runner)
      eventually(fn -> Process.info(runner, :message_queue_len) == {:message_queue_len, 1} end)
      publish_pair(3)
      :ok = :sys.resume(runner)

      assert_receive {:exported, :stereo_pair, 3, _at}, 1_000
      refute_receive {:exported, :stereo_pair, _pair, _at}, 300
    end

    test "a slot timer from before a hand-over does not hand the next value over early" do
      runner = start_forwarder(outputs: [stereo_pair: [max_hz: 5]])
      publish_pair(1)
      assert_receive {:exported, :stereo_pair, 1, _at}
      publish_pair(2)
      Process.sleep(50)

      # White-box: the hand-over that happens at a slot's edge, a fraction of a millisecond
      # before that slot's timer fires, which cannot be timed from outside the runner.
      handed_ms = System.monotonic_time(:millisecond)

      :sys.replace_state(runner, fn state ->
        update_in(state.slots.stereo_pair, fn slot ->
          slot |> Map.merge(%{handed_ms: handed_ms, held: nil}) |> Map.replace(:timer, nil)
        end)
      end)

      publish_pair(3)

      assert_receive {:exported, :stereo_pair, 3, third_ms}, 1_000
      assert third_ms - handed_ms >= 200
    end

    test "an exporter that says it is busy is handed nothing more of that output until it is ready" do
      runner = start_runner(Slow, [])
      publish_pair(1)
      assert_receive {:exported, :stereo_pair, 1}

      publish_pair(2)
      publish_pair(3)
      :sys.get_state(runner)
      refute_received {:exported, :stereo_pair, _pair}

      send(runner, :sent)
      assert_receive {:exported, :stereo_pair, 3}
      publish_pair(4)
      :sys.get_state(runner)
      refute_received {:exported, :stereo_pair, _pair}

      send(runner, :sent)
      assert_receive {:exported, :stereo_pair, 4}
      refute_received {:exported, :stereo_pair, 2}
    end

    test "one ready message ends the busy hand-off of every output it names" do
      runner = start_runner(SlowPair, [])
      publish_pair(1)
      publish_detections(1)
      assert_receive {:exported, :stereo_pair, 1, _at}
      assert_receive {:exported, :detections, {1, []}, _at}

      publish_pair(2)
      publish_detections(2)
      :sys.get_state(runner)
      refute_received {:exported, _output, _value, _at}

      send(runner, :sent)
      assert_receive {:exported, :detections, {2, []}, _at}
      assert_receive {:exported, :stereo_pair, 2, _at}, 1_000
    end

    test "an output ready again before its slot opens is handed its newest value at the slot" do
      runner = start_runner(SlowPair, [])
      publish_pair(1)
      assert_receive {:exported, :stereo_pair, 1, first_ms}

      publish_pair(2)
      publish_pair(3)
      send(runner, :sent)

      assert_receive {:exported, :stereo_pair, 3, third_ms}, 1_000

      # Whole milliseconds, each read just after the runner's own reading: a tick may fall between.
      assert third_ms - first_ms >= 200 - 1
      refute_received {:exported, :stereo_pair, 2, _at}
    end
  end

  describe "status" do
    test "answers the exporter's status, or running for one that reports none" do
      counter = start_runner(Counter, [], Counter)
      forwarder = start_forwarder(outputs: [:stereo_pair])

      publish_pair(:pair)

      assert Runner.status(counter) == {:ok, "1 pairs"}
      assert Runner.status(forwarder) == {:ok, "Running"}
    end

    test "a busy exporter's status is a warning by the deadline, not a wait" do
      runner = start_forwarder(outputs: [:stereo_pair], block_on: :pair)
      publish_pair(:pair)
      assert_receive {:exported, :stereo_pair, :pair, _at}

      {elapsed_us, status} = :timer.tc(fn -> Runner.status(runner, 100) end)

      assert {:warning, _message} = status
      assert elapsed_us < 300_000
      send(runner, :release)
    end

    test "a runner that is not running is off" do
      runner = start_forwarder(outputs: [])
      stop_supervised!(Runner)

      assert {:off, _message} = Runner.status(runner)
    end

    test "a status/1 that fails is a warning, logged once, and the exporter keeps exporting" do
      runner = start_runner(FailingStatus, [])

      log =
        capture_log(fn ->
          assert Runner.status(runner) == {:warning, "Status failed: no link"}
          assert Runner.status(runner) == {:warning, "Status failed: no link"}
        end)

      publish_pair(:pair)

      assert_receive {:exported, :stereo_pair, :pair}
      assert length(String.split(log, "no link")) == 2
    end

    test "a status/1 that answers no status is a warning that says what it answered, logged once" do
      for malformed <- [
            :ok,
            {"ok", "Connected"},
            {:ok, :connected},
            {:good, "Fine"},
            {:ok, "a", "b"}
          ] do
        runner = start_runner(GivenStatus, [status: malformed], {GivenStatus, malformed})

        log =
          capture_log(fn ->
            assert Runner.status(runner) == {:warning, "Malformed status: #{inspect(malformed)}"}
            assert Runner.status(runner) == {:warning, "Malformed status: #{inspect(malformed)}"}
          end)

        assert length(String.split(log, "#{inspect(GivenStatus)} status/1 answered")) == 2
      end
    end

    test "a status/1 that answers a status passes it on" do
      for status <- [{:ok, "Connected"}, {:warning, "Disconnected"}, {:off, "Idle"}] do
        runner = start_runner(GivenStatus, [status: status], {GivenStatus, status})
        assert Runner.status(runner) == status
      end
    end

    test "values the exporter could not export show in the default status, each reason logged once" do
      runner = start_forwarder(outputs: [:stereo_pair], reject: [1, 2])

      log =
        capture_log(fn ->
          publish_pair(1)
          assert_receive {:exported, :stereo_pair, 1, _at}
          publish_pair(2)
          assert_receive {:exported, :stereo_pair, 2, _at}

          assert Runner.status(runner) ==
                   {:warning, "2 values not exported, the last for :rejected"}
        end)

      publish_pair(3)
      assert_receive {:exported, :stereo_pair, 3, _at}

      assert Runner.status(runner) == {:ok, "Running; 2 values not exported"}
      assert length(String.split(log, ":rejected")) == 2
    end

    test "an output whose last value was not exported is a warning while another output exports" do
      runner = start_forwarder(outputs: [:stereo_pair, :detections], reject: [1])
      publish_pair(1)
      assert_receive {:exported, :stereo_pair, 1, _at}
      publish_detections(:pair)
      assert_receive {:exported, :detections, {:pair, []}, _at}

      assert Runner.status(runner) == {:warning, "1 values not exported, the last for :rejected"}

      publish_pair(2)
      assert_receive {:exported, :stereo_pair, 2, _at}

      assert Runner.status(runner) == {:ok, "Running; 1 values not exported"}
    end

    test "values not exported for many reasons leave a failing status/1 still logged" do
      runner = start_runner(Refusing, [])

      log =
        capture_log(fn ->
          for pair <- 1..40 do
            publish_pair(pair)
            assert_receive {:exported, :stereo_pair, ^pair}
          end

          assert Runner.status(runner) == {:warning, "Status failed: no link"}
        end)

      assert log =~ "status failed: no link"
    end
  end

  describe "start" do
    test "an exporter whose init/1 fails is not started, said so, and tried again until it starts" do
      {:ok, attempts} = Agent.start_link(fn -> [{:error, :storage_not_mounted}] end)
      runner = start_runner(LateStart, attempts: attempts)

      assert Runner.status(runner) == {:warning, "Not started: :storage_not_mounted"}
      refute runner in Outputs.subscribers(@pairs)

      eventually(fn -> Runner.status(runner) == {:ok, "Running"} end)
      publish_pair(:pair)

      assert_receive {:exported, :stereo_pair, :pair}
    end

    test "an init/1 that raises is tried again too" do
      {:ok, attempts} = Agent.start_link(fn -> [:raise] end)
      runner = start_runner(LateStart, attempts: attempts)

      assert Runner.status(runner) ==
               {:warning, "Not started: the recordings directory is missing"}

      eventually(fn -> Runner.status(runner) == {:ok, "Running"} end)
    end

    test "a started exporter is not started again" do
      runner = start_runner(Announcing, [])
      assert_received {:initialised, ^runner}

      send(runner, {Runner, :start_exporter})
      :sys.get_state(runner)

      refute_received {:initialised, _runner}
    end
  end

  describe "actions" do
    test "runs an action that answers at once" do
      runner = start_runner(Acting, [])

      assert Runner.action(runner, "ping", %{}, 1000) == {:ok, %{pong: true}}
    end

    test "runs an action that answers later, from handle_info" do
      runner = start_runner(Acting, [])

      task = Task.async(fn -> Runner.action(runner, "later", %{}, 1000) end)
      assert_receive :pending
      send(runner, :finish)

      assert Task.await(task) == {:ok, %{done: true}}
    end

    test "answers its status while an action is pending" do
      runner = start_runner(Acting, [])

      task = Task.async(fn -> Runner.action(runner, "later", %{}, 1000) end)
      assert_receive :pending

      assert Runner.status(runner) == {:ok, "Running"}

      send(runner, :finish)
      assert Task.await(task) == {:ok, %{done: true}}
    end

    test "an action that raises answers why it failed, logged, and the runner runs on" do
      runner = start_runner(Acting, [])

      log =
        capture_log(fn ->
          assert Runner.action(runner, "raise", %{}, 1000) == {:error, {:failed, "boom"}}
        end)

      assert log =~ "boom"
      assert Process.alive?(runner)
      assert Runner.action(runner, "ping", %{}, 1000) == {:ok, %{pong: true}}
    end

    test "an action that answers no result fails, the exporter's state kept, and the runner runs on" do
      runner = start_runner(Acting, [])
      task = Task.async(fn -> Runner.action(runner, "later", %{}, 1000) end)
      assert_receive :pending

      assert {:error, {:failed, message}} = Runner.action(runner, "malformed", %{}, 1000)
      assert message =~ "handle_action/4 returned"

      send(runner, :finish)
      assert Task.await(task) == {:ok, %{done: true}}
      assert Process.alive?(runner)
    end

    test "refuses an action it does not declare, without creating an atom" do
      runner = start_runner(Acting, [])
      name = "zz_not_an_atom_#{System.unique_integer([:positive])}"

      assert Runner.action(runner, name, %{}, 1000) == {:error, :unknown_action}
      assert_raise ArgumentError, fn -> String.to_existing_atom(name) end
      assert Runner.status(runner) == {:ok, "Running"}
    end

    test "answers not running before init/1 succeeds" do
      runner = start_runner(Acting, init: {:error, :not_ready})

      assert Runner.action(runner, "ping", %{}, 1000) == {:error, :not_running}
    end
  end

  test "answers a call it does not know with an error, and runs on" do
    runner = start_forwarder([outputs: [:stereo_pair]], config())

    assert GenServer.call(runner, :flush) == {:error, :unknown_call}
    assert Runner.status(runner) == {:ok, "Running"}
  end

  test "hands the exporter's own messages to its handle_info/2, and drops them without one" do
    start_runner(Counter, [], Counter)
    forwarder = start_forwarder(outputs: [])

    send(forwarder, :tick)

    assert_receive :ticked
    assert {:ok, _running} = Runner.status(forwarder)
  end

  test "calls the exporter's terminate/2 when its supervisor shuts it down" do
    start_runner(Closing, [])

    stop_supervised!(Runner)

    assert_receive {:terminated, :shutdown}
  end
end
