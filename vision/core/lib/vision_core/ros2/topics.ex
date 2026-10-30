defmodule VisionCore.Ros2.Topics do
  @moduledoc """
  Every topic the vision core has published, with its message type and
  live rate.

  `VisionCore.Ros2.ZenohClient.publish/4` calls `count/2` from the
  publishing process: one `:ets.update_counter/4` on a public table this
  process owns, so a publisher never waits on a server. Once a second the
  counts since the previous tick become each topic's rate. Names are full
  ROS names, with a leading `/`; types are the ROS type names
  (`sensor_msgs/msg/Image`) derived from the message module's `dds_type/0`.
  """
  use GenServer

  @table __MODULE__
  @tick_ms 1_000

  @type topic :: %{name: String.t(), type: String.t(), rate_hz: float()}

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Counts one publish of `message_module` on `topic`; a no-op while this process is down."
  @spec count(String.t(), module()) :: :ok
  def count(topic, message_module) do
    name = full_name(topic)
    :ets.update_counter(@table, name, {2, 1}, {name, 0, message_module})
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
      |> Enum.map(fn {name, _count, module} ->
        %{name: name, type: ros_type(module), rate_hz: Map.get(state.rates, name, 0.0)}
      end)
      |> Enum.sort_by(& &1.name)

    {:reply, topics, state}
  end

  @impl GenServer
  def handle_info(:tick, state) do
    now = System.monotonic_time(:millisecond)
    elapsed_s = max(now - state.ticked_at, 1) / 1_000
    counts = Map.new(:ets.tab2list(@table), fn {name, count, _module} -> {name, count} end)

    rates =
      Map.new(counts, fn {name, count} ->
        {name, Float.round((count - Map.get(state.counts, name, 0)) / elapsed_s, 1)}
      end)

    schedule_tick()
    {:noreply, %{state | counts: counts, rates: rates, ticked_at: now}}
  end

  defp schedule_tick, do: Process.send_after(self(), :tick, @tick_ms)

  @doc "`topic` as a full ROS name, with a leading `/`."
  @spec full_name(String.t()) :: String.t()
  def full_name("/" <> _rest = name), do: name
  def full_name(name), do: "/" <> name

  @doc "The ROS type name of a message or service module (`sensor_msgs/msg/Image`), or its module name."
  @spec ros_type(module()) :: String.t()
  def ros_type(module) do
    Code.ensure_loaded(module)

    if function_exported?(module, :dds_type, 0) do
      module.dds_type()
      |> String.replace("::dds_::", "::")
      |> String.replace("::", "/")
      |> String.trim_trailing("_")
    else
      inspect(module)
    end
  end
end
