defmodule VisionCore.Ros2.Bag.Buffer do
  @moduledoc """
  The messages of a `VisionCore.Ros2.Bag.Recording` that its writer has
  not written yet, so that a slow disk does not stall the processes
  handing them over.

  `put/5` admits an encoded message against the buffer's bytes, in the
  caller, and hands it to the buffer's process, which never waits on the
  writer: it hands the writer one message at a time, the next once the
  writer calls `written/1`. A message counts against the bytes until then.
  `close/1` answers the messages not written, the one handed over
  included, and stops the process. The process stops with the writer,
  which starts it.
  """
  use GenServer

  alias VisionCore.Ros2.Bag.Recording

  @enforce_keys [:pid, :held_bytes, :max_bytes]
  defstruct @enforce_keys

  @typedoc "A buffer: its process, its bytes held and the most it holds."
  @type t :: %__MODULE__{
          pid: pid(),
          held_bytes: :atomics.atomics_ref(),
          max_bytes: non_neg_integer()
        }

  @typedoc "A message as the writer takes it: topic, message module, CDR payload, log time."
  @type message :: {String.t(), module(), binary(), non_neg_integer()}

  @doc "Starts the buffer of `writer`, linked to the caller, holding at most `max_bytes` of payloads."
  @spec start_link(pid(), non_neg_integer()) :: {:ok, t()}
  def start_link(writer, max_bytes) do
    held_bytes = :atomics.new(1, signed: true)
    {:ok, pid} = GenServer.start_link(__MODULE__, {writer, held_bytes})
    {:ok, %__MODULE__{pid: pid, held_bytes: held_bytes, max_bytes: max_bytes}}
  end

  @doc """
  Hands the buffer `payload`, of `module`, on `topic` at `log_time_ns`;
  `:full` without it when the payloads held and it pass `max_bytes`.
  """
  @spec put(t(), String.t(), module(), binary(), non_neg_integer()) :: :ok | :full
  def put(buffer, topic, module, payload, log_time_ns) do
    bytes = byte_size(payload)

    if :atomics.add_get(buffer.held_bytes, 1, bytes) > buffer.max_bytes do
      :atomics.sub(buffer.held_bytes, 1, bytes)
      :full
    else
      GenServer.cast(buffer.pid, {:put, {topic, module, payload, log_time_ns}})
    end
  end

  @doc "Tells the buffer the writer wrote the message it was handed."
  @spec written(t()) :: :ok
  def written(buffer), do: GenServer.cast(buffer.pid, :written)

  @doc "The messages not written yet, in order, the one handed over first; stops the buffer."
  @spec close(t()) :: [message()]
  def close(buffer) do
    GenServer.call(buffer.pid, :close)
  catch
    :exit, _reason -> []
  end

  @impl GenServer
  def init({writer, held_bytes}) do
    Process.flag(:trap_exit, true)
    {:ok, %{writer: writer, held_bytes: held_bytes, messages: :queue.new(), handed: false}}
  end

  @impl GenServer
  def handle_cast({:put, message}, state),
    do: {:noreply, hand_next(%{state | messages: :queue.in(message, state.messages)})}

  def handle_cast(:written, state) do
    {{:value, {_topic, _module, payload, _log_time}}, messages} = :queue.out(state.messages)
    :atomics.sub(state.held_bytes, 1, byte_size(payload))
    {:noreply, hand_next(%{state | messages: messages, handed: false})}
  end

  @impl GenServer
  def handle_call(:close, _from, state),
    do: {:stop, :normal, :queue.to_list(state.messages), state}

  defp hand_next(%{handed: true} = state), do: state

  defp hand_next(state) do
    case :queue.peek(state.messages) do
      {:value, message} ->
        Recording.write_encoded(state.writer, message)
        %{state | handed: true}

      :empty ->
        state
    end
  end
end
