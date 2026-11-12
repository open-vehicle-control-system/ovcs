defmodule VisionCore.Live do
  @moduledoc """
  The latest result of a pipeline, for the dashboard: takes what the
  pipeline publishes through `VisionCore.Outputs` and hands each
  subscriber what the dashboard draws of it, at most `:max_hz` times a
  second. A result that comes sooner is held and sent once the interval
  has passed, unless a newer one replaces it, so the latest always
  arrives. Nothing is made of a result while no process subscribes.

  `VisionCore.Detection.Live` and `VisionCore.Segmentation.Live` each
  start one per pipeline and say what a result becomes.

  ## Options

    * `:name` (required) — the name it registers under.
    * `:key` (required) — the `VisionCore.Outputs` key the pipeline
      publishes under.
    * `:tag` (required) — a subscriber receives `{tag, result}`.
    * `:describe` (required) — what a published message becomes for a
      subscriber, `{:ok, result}`, or `:ignore` for a message that is no
      result.
    * `:max_hz` (required) — results a second sent to each subscriber,
      an integer from 1 on (`VisionCore.Options`).
  """
  use GenServer

  alias VisionCore.{Options, Outputs}

  def start_link(opts),
    do: GenServer.start_link(__MODULE__, opts, name: Keyword.fetch!(opts, :name))

  @doc "Sends the calling process every later result `server` hands on, until it exits."
  @spec subscribe(GenServer.server()) :: :ok
  def subscribe(server), do: GenServer.call(server, {:subscribe, self()})

  @doc "The most results a subscriber of `server` receives a second, its `:max_hz`."
  @spec max_hz(GenServer.server()) :: pos_integer()
  def max_hz(server), do: GenServer.call(server, :max_hz)

  @impl GenServer
  def init(opts) do
    max_hz = Options.integer!(opts, :max_hz, nil, 1)
    :ok = Outputs.subscribe(Keyword.fetch!(opts, :key))

    {:ok,
     %{
       tag: Keyword.fetch!(opts, :tag),
       describe: Keyword.fetch!(opts, :describe),
       max_hz: max_hz,
       interval_ms: div(1_000, max_hz),
       subscribers: %{},
       sent_at_ms: nil,
       held: nil
     }}
  end

  @impl GenServer
  def handle_call(:max_hz, _from, state), do: {:reply, state.max_hz, state}

  def handle_call({:subscribe, pid}, _from, state) do
    subscribers = Map.put_new_lazy(state.subscribers, pid, fn -> Process.monitor(pid) end)
    {:reply, :ok, %{state | subscribers: subscribers}}
  end

  @impl GenServer
  def handle_cast(_message, %{subscribers: subscribers} = state) when map_size(subscribers) == 0,
    do: {:noreply, state}

  def handle_cast(message, state) do
    case state.describe.(message) do
      {:ok, result} -> {:noreply, hand_on(result, state)}
      :ignore -> {:noreply, state}
    end
  end

  defp hand_on(result, state) do
    now_ms = System.monotonic_time(:millisecond)

    cond do
      due?(state, now_ms) ->
        send_result(result, now_ms, state)

      is_nil(state.held) ->
        Process.send_after(self(), :send_held, state.sent_at_ms + state.interval_ms - now_ms)
        %{state | held: {:result, result}}

      true ->
        %{state | held: {:result, result}}
    end
  end

  @impl GenServer
  def handle_info(:send_held, %{held: nil} = state), do: {:noreply, state}

  def handle_info(:send_held, %{held: {:result, result}} = state),
    do: {:noreply, send_result(result, System.monotonic_time(:millisecond), state)}

  def handle_info({:DOWN, _reference, :process, pid, _reason}, state),
    do: {:noreply, %{state | subscribers: Map.delete(state.subscribers, pid)}}

  def handle_info(_message, state), do: {:noreply, state}

  defp send_result(result, now_ms, state) do
    for pid <- Map.keys(state.subscribers), do: send(pid, {state.tag, result})
    %{state | sent_at_ms: now_ms, held: nil}
  end

  defp due?(%{sent_at_ms: nil}, _now_ms), do: true
  defp due?(state, now_ms), do: now_ms - state.sent_at_ms >= state.interval_ms
end
