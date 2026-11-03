defmodule VisionCore.Outputs do
  @moduledoc """
  Carries what the vision unit's producers publish to the processes that
  consume it, through a `Registry` of subscriptions.

  A producer publishes under the key of its output, `{output, name}`:
  `output` is the tag of the messages it sends and `name` its own
  registered name, so two producers of one kind stay apart.

    * `{:camera_frame, name}` — `{:camera_frame, %VisionCore.Camera.Frame{}}`
      from the `VisionCore.Camera` driver instance registered as `name`.
    * `{:stereo_pair, name}` — `{:stereo_pair, %VisionCore.Stereo.Pair{}}`
      from the `VisionCore.Stereo.Pipeline` started as `name`.
    * `{:detections, name}` — `{:detections, pair, detections}` from the
      `VisionCore.Detection.Pipeline` registered as `name`.

  A consumer subscribes to the keys it reads and receives each message
  as a cast. A subscription belongs to the subscriber, not to the
  producer: it holds before the producer starts and across its restarts,
  and goes when the subscriber exits. Every subscriber receives every
  message, so one that falls behind lets its mailbox grow.

  `VisionCore.Application` starts the registry before the components: a
  process may subscribe from its `init/1`, and a registry that restarts
  restarts the components with it, which subscribe again. A partition of
  the registry that crashes restarts alone and empty, but each subscriber
  is linked to its partition: the crash takes the subscribers down, and
  their supervisors restart them, subscribing again. A subscriber that
  traps exits gets the crash as a message instead, and must subscribe
  again itself.
  """

  @typedoc "An output and the name of the producer publishing it."
  @type key :: {:camera_frame | :stereo_pair | :detections, atom()}

  @doc "Starts the registry."
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(_opts \\ []), do: Registry.start_link(keys: :duplicate, name: __MODULE__)

  @doc false
  def child_spec(opts),
    do: %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}, type: :supervisor}

  @doc """
  Sends the calling process every later message published under `key`,
  until it exits or unsubscribes. Subscribing again to a key changes
  nothing.
  """
  @spec subscribe(key()) :: :ok
  def subscribe(key) do
    if Registry.values(__MODULE__, key, self()) == [] do
      {:ok, _owner} = Registry.register(__MODULE__, key, nil)
    end

    :ok
  end

  @doc "Stops sending the calling process the messages published under `key`."
  @spec unsubscribe(key()) :: :ok
  def unsubscribe(key), do: Registry.unregister(__MODULE__, key)

  @doc "Casts `message` to every process subscribed to `key`."
  @spec publish(key(), term()) :: :ok
  def publish(key, message) do
    Registry.dispatch(__MODULE__, key, fn subscriptions ->
      for {subscriber, _value} <- subscriptions, do: GenServer.cast(subscriber, message)
    end)
  end

  @doc "The processes subscribed to `key`."
  @spec subscribers(key()) :: [pid()]
  def subscribers(key) do
    for {subscriber, _value} <- Registry.lookup(__MODULE__, key), do: subscriber
  end
end
