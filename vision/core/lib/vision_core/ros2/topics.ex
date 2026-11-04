defmodule VisionCore.Ros2.Topics do
  @moduledoc """
  Every topic the vision core has published or tried to, with its message
  type, live rate and the count of its messages that could not be encoded.

  `publish/4` publishes through `Ros2Zenoh.Client` and calls `count/2`, or
  `count_encode_failure/2` for a message that could not be encoded, from
  the publishing process: one `:ets.update_counter/4` on a public table this
  process owns, so a publisher never waits on a server. Once a second the
  counts since the previous tick become each topic's rate. Names are full
  ROS names, with a leading `/`; types are the ROS type names
  (`sensor_msgs/msg/Image`) derived from the message module's `dds_type/0`.
  """
  use GenServer

  @table __MODULE__
  @tick_ms 1_000

  @type topic :: %{
          name: String.t(),
          type: String.t(),
          rate_hz: float(),
          encode_failures: non_neg_integer()
        }

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  Publishes `message` on `topic` with `Ros2Zenoh.Client.publish/4` and
  counts it: as a publish when the client took it, dropped for want of a
  session included, as an encode failure when it could not be encoded.
  Answers what the client answered.
  """
  @spec publish(String.t(), module(), struct(), keyword()) ::
          :ok | {:error, {:encode_raised, String.t()}}
  def publish(topic, message_module, message, opts \\ []) do
    case Ros2Zenoh.Client.publish(topic, message_module, message, opts) do
      :ok ->
        count(topic, message_module)

      {:error, {:encode_raised, _reason}} = error ->
        count_encode_failure(topic, message_module)
        error
    end
  end

  @doc "Counts one publish of `message_module` on `topic`; a no-op while this process is down."
  @spec count(String.t(), module()) :: :ok
  def count(topic, message_module) do
    name = full_name(topic)
    :ets.update_counter(@table, name, {2, 1}, {name, 0, message_module, 0})
    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc """
  Counts one `message_module` message for `topic` that could not be
  encoded. It is not a publish: it adds nothing to the topic's rate. A
  no-op while this process is down.
  """
  @spec count_encode_failure(String.t(), module()) :: :ok
  def count_encode_failure(topic, message_module) do
    name = full_name(topic)
    :ets.update_counter(@table, name, {4, 1}, {name, 0, message_module, 0})
    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc "The topics published so far, sorted by name; `[]` while this process is down."
  @spec topics() :: [topic()]
  def topics do
    GenServer.call(__MODULE__, :topics)
  catch
    :exit, _reason -> []
  end

  @impl GenServer
  def init(_opts) do
    :ets.new(@table, [:named_table, :public, :set, write_concurrency: true])
    schedule_tick()
    {:ok, %{counts: %{}, rates: %{}, ticked_at: System.monotonic_time(:millisecond)}}
  end

  @impl GenServer
  def handle_call(:topics, _from, state) do
    topics =
      :ets.tab2list(@table)
      |> Enum.map(fn {name, _count, module, encode_failures} ->
        %{
          name: name,
          type: ros_type(module),
          rate_hz: Map.get(state.rates, name, 0.0),
          encode_failures: encode_failures
        }
      end)
      |> Enum.sort_by(& &1.name)

    {:reply, topics, state}
  end

  @impl GenServer
  def handle_info(:tick, state) do
    now = System.monotonic_time(:millisecond)
    elapsed_s = max(now - state.ticked_at, 1) / 1_000

    counts =
      Map.new(:ets.tab2list(@table), fn {name, count, _module, _failures} -> {name, count} end)

    rates =
      Map.new(counts, fn {name, count} ->
        {name, Float.round((count - Map.get(state.counts, name, 0)) / elapsed_s, 1)}
      end)

    schedule_tick()
    {:noreply, %{state | counts: counts, rates: rates, ticked_at: now}}
  end

  defp schedule_tick, do: Process.send_after(self(), :tick, @tick_ms)

  defdelegate full_name(topic), to: Ros2Zenoh
  defdelegate ros_type(module), to: Ros2Zenoh
end
