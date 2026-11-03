defmodule VisionCore.OutputsTest do
  use ExUnit.Case, async: true

  alias VisionCore.Outputs

  # Publishes under its own name, as the camera drivers and the pipelines do.
  defmodule Producer do
    use GenServer

    def start_link(name), do: GenServer.start_link(__MODULE__, name, name: name)
    def produce(name, pair), do: GenServer.call(name, {:produce, pair})

    @impl GenServer
    def init(name), do: {:ok, {:stereo_pair, name}}

    @impl GenServer
    def handle_call({:produce, pair}, _from, key) do
      :ok = Outputs.publish(key, {:stereo_pair, pair})
      {:reply, :ok, key}
    end
  end

  defp eventually(check, attempts \\ 100) do
    cond do
      check.() -> :ok
      attempts == 0 -> flunk("condition not met")
      true -> Process.sleep(10) && eventually(check, attempts - 1)
    end
  end

  test "delivers what is published under a key to its subscribers, as a cast", %{test: name} do
    key = {:stereo_pair, name}
    assert :ok = Outputs.subscribe(key)

    assert :ok = Outputs.publish(key, {:stereo_pair, 1})

    assert_received {:"$gen_cast", {:stereo_pair, 1}}
  end

  test "a process subscribes to several keys, once to each however often it asks",
       %{test: name} do
    pairs = {:stereo_pair, name}
    frames = {:camera_frame, name}

    :ok = Outputs.subscribe(pairs)
    :ok = Outputs.subscribe(pairs)
    :ok = Outputs.subscribe(frames)
    Outputs.publish(pairs, {:stereo_pair, 1})
    Outputs.publish(frames, {:camera_frame, 2})

    assert_received {:"$gen_cast", {:stereo_pair, 1}}
    assert_received {:"$gen_cast", {:camera_frame, 2}}
    refute_received {:"$gen_cast", _message}
    assert Outputs.subscribers(pairs) == [self()]
  end

  test "publishing with no subscriber delivers nothing", %{test: name} do
    assert :ok = Outputs.publish({:stereo_pair, name}, {:stereo_pair, 1})
    refute_received {:"$gen_cast", _message}
  end

  test "stops delivering to a process once it unsubscribes", %{test: name} do
    key = {:stereo_pair, name}
    :ok = Outputs.subscribe(key)

    assert :ok = Outputs.unsubscribe(key)
    Outputs.publish(key, {:stereo_pair, 1})

    refute_received {:"$gen_cast", _message}
    assert Outputs.subscribers(key) == []
  end

  test "a subscriber that exits leaves with its subscriptions", %{test: name} do
    key = {:stereo_pair, name}
    test = self()

    subscriber =
      spawn(fn ->
        :ok = Outputs.subscribe(key)
        send(test, :subscribed)
        receive do: (:stop -> :ok)
      end)

    assert_receive :subscribed
    assert Outputs.subscribers(key) == [subscriber]
    monitor = Process.monitor(subscriber)
    send(subscriber, :stop)
    assert_receive {:DOWN, ^monitor, :process, _pid, :normal}

    eventually(fn -> Outputs.subscribers(key) == [] end)
  end

  test "a subscription outlives its producer's restarts", %{test: name} do
    :ok = Outputs.subscribe({:stereo_pair, name})
    first = start_supervised!({Producer, name})
    Producer.produce(name, 1)

    Process.exit(first, :kill)
    eventually(fn -> Process.whereis(name) not in [nil, first] end)
    Producer.produce(name, 2)

    assert_receive {:"$gen_cast", {:stereo_pair, 1}}
    assert_receive {:"$gen_cast", {:stereo_pair, 2}}
  end

  test "keeps two producers of one kind apart by their names", %{test: name} do
    left = :"#{name} left"
    right = :"#{name} right"
    start_supervised!(Supervisor.child_spec({Producer, left}, id: left))
    start_supervised!(Supervisor.child_spec({Producer, right}, id: right))
    :ok = Outputs.subscribe({:stereo_pair, left})

    Producer.produce(right, :right)
    Producer.produce(left, :left)

    assert_receive {:"$gen_cast", {:stereo_pair, :left}}
    refute_received {:"$gen_cast", {:stereo_pair, :right}}
  end
end
