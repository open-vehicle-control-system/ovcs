defmodule VisionCore.Outputs do
  @moduledoc """
  Carries what the vision unit's producers publish to the processes that
  consume it, through a `Registry` of subscriptions.

  A producer publishes under the key of its output, `{output, name}`:
  `output` is its kind and `name` the producer's registered name, its
  pipeline's name, or the stereo unit's prefix for a calibration, so two
  producers of one kind stay apart.

    * `{:camera_frame, name}` — `{:camera_frame, %VisionCore.Camera.Frame{}}`
      from the `VisionCore.Camera` driver instance registered as `name`;
      `{:camera_frame, name, output}` from one with named outputs, the
      frames of its output `output` (`VisionCore.Camera.Unit.output_key/3`).
    * `{:stereo_pair, name}` — `{:stereo_pair, %VisionCore.Stereo.Pair{}}`
      from the `VisionCore.Stereo.Pipeline` started as `name`.
    * `{:detections, name}` — `{output, {pair, detections}}` from the
      detection pipeline `name` (`VisionCore.Detection.Pipeline`),
      `output` being the key, its `VisionCore.Exporter` output, and the
      `%VisionCore.Camera.Frame{}` the boxes were found on, without its
      pixels, in place of `pair` on a camera source.
    * `{:segmentation, name}` — `{output, {frame, labels, clouds}}` from
      the segmentation pipeline `name`
      (`VisionCore.Segmentation.Pipeline`), `output` being the key.
    * `{:stereo_calibration, prefix}` — `{:stereo_calibration_changed, prefix}`
      from `VisionCore.Stereo.Calibration`, after each change of the
      calibration of the stereo unit `prefix`.
    * `{:camera_calibration, name}` — `{:camera_calibration_changed, name}`
      from `VisionCore.Camera.Calibration`, after each change of the
      calibration of the camera `name`.
    * `{:camera_pose, name}` — `{:camera_pose_changed, name}` from
      `VisionCore.Camera.Pose`, after each change of the pose of the
      camera `name`.
    * `{:saved_calibrations, target}` — `{:saved_calibrations_changed, target}`
      from `VisionCore.Calibration.Recorder`, after each change of the
      calibrations kept for the calibration target `target`.

  A consumer subscribes to the keys it reads and receives each message
  as a cast. One that takes messages out of its mailbox itself matches
  them with `queued/1`. A subscription belongs to the subscriber, not to the
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
  @type key ::
          {:camera_frame | :stereo_pair | :detections | :segmentation, atom()}
          | {:camera_frame, atom(), atom()}
          | {:stereo_calibration, String.t()}
          | {:camera_calibration, atom()}
          | {:camera_pose, atom()}
          | {:saved_calibrations, String.t()}

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

  @doc """
  The pattern of `message`, published, as it waits in a subscriber's
  mailbox, for a `receive` that takes it out ahead of the others:

      receive do
        Outputs.queued({:stereo_pair, pair}) -> pair
      after
        0 -> nil
      end
  """
  defmacro queued(message), do: quote(do: {:"$gen_cast", unquote(message)})

  @doc "The processes subscribed to `key`."
  @spec subscribers(key()) :: [pid()]
  def subscribers(key) do
    for {subscriber, _value} <- Registry.lookup(__MODULE__, key), do: subscriber
  end
end
