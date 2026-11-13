defmodule VisionCore.Video do
  @moduledoc """
  Relays the H.264 outputs of the vision unit's cameras
  (`VisionCore.Camera.Output`) to the dashboard, one video per camera,
  beside `VisionCore.Preview`'s JPEG previews.

  A subscriber receives `{:vision_video, camera, frame}`, each frame of
  the camera's video in order from the next key frame
  (`VisionCore.Camera.Frame`, its `:h264` and `:keyframe?`), and calls
  `ack/1` once it has handled one. At most `:in_flight_frames` frames
  are unacknowledged at once; the others wait in the subscriber's
  `VisionCore.Camera.VideoQueue`, which holds at most `:backlog_frames`
  and past that skips to the next key frame, so a slow link drops whole
  groups of frames instead of holding a growing backlog.

  `VisionCore.Application` starts it after the components, with the
  `:videos` of the configuration's `:preview` options.

  ## Options

    * `:config` — the active `VisionCore.Config` (required).
    * `:videos` (`[]`) — the H.264 output relayed for each camera, by
      camera name (`center: :view_h264`). An output that is no H.264
      output of the camera is logged and not relayed.
    * `:in_flight_frames` (`10`), `:backlog_frames` (`30`) — the
      unacknowledged frames and the queued frames a subscriber may have.
  """
  use GenServer
  require Logger

  alias VisionCore.Camera.{Frame, Unit, VideoQueue}
  alias VisionCore.Outputs

  @default_in_flight_frames 10
  @default_backlog_frames 30

  @doc "Starts the relay; see the module doc for the options."
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  Sends the caller the frames of `camera`'s video as `{:vision_video,
  camera, frame}` until it exits; `{:error, :unknown_video}` for a camera
  whose video it does not relay.
  """
  @spec subscribe(atom()) :: :ok | {:error, :unknown_video}
  def subscribe(camera) when is_atom(camera),
    do: GenServer.call(__MODULE__, {:subscribe, self(), camera})

  @doc "Tells the relay the caller has handled one more of `camera`'s frames."
  @spec ack(atom()) :: :ok
  def ack(camera) when is_atom(camera), do: GenServer.cast(__MODULE__, {:ack, self(), camera})

  @doc "The video relayed for each camera, `[camera: output]`, in the configuration's order."
  @spec videos() :: keyword(atom())
  def videos, do: GenServer.call(__MODULE__, :videos)

  @impl GenServer
  def init(opts) do
    config = Keyword.fetch!(opts, :config)
    videos = Enum.filter(Keyword.get(opts, :videos, []), &relayable?(config, &1))

    for {camera, output} <- videos,
        do: :ok = Outputs.subscribe(Unit.video_key(config, camera, output))

    {:ok,
     %{
       videos: videos,
       cameras: Map.new(videos, fn {camera, _output} -> {Atom.to_string(camera), camera} end),
       in_flight_frames: Keyword.get(opts, :in_flight_frames, @default_in_flight_frames),
       backlog_frames: Keyword.get(opts, :backlog_frames, @default_backlog_frames),
       subscribers: %{}
     }}
  end

  defp relayable?(config, {camera, output}) do
    relayable = Unit.video_output?(config, camera, output)

    unless relayable,
      do:
        Logger.error(
          "#{inspect(__MODULE__)}: camera #{camera} has no H.264 output #{inspect(output)}; " <>
            "its video is not relayed"
        )

    relayable
  end

  @impl GenServer
  def handle_call(:videos, _from, state), do: {:reply, state.videos, state}

  def handle_call({:subscribe, pid, camera}, _from, state) do
    cond do
      not Keyword.has_key?(state.videos, camera) ->
        {:reply, {:error, :unknown_video}, state}

      is_map_key(state.subscribers, {pid, camera}) ->
        {:reply, :ok, state}

      true ->
        subscriber = %{
          monitor: Process.monitor(pid),
          in_flight: 0,
          queue: VideoQueue.new(state.backlog_frames)
        }

        {:reply, :ok, put_in(state.subscribers[{pid, camera}], subscriber)}
    end
  end

  @impl GenServer
  def handle_cast({:camera_frame, %Frame{label: label} = frame}, state)
      when is_map_key(state.cameras, label) do
    camera = Map.fetch!(state.cameras, label)

    subscribers =
      Map.new(state.subscribers, fn
        {{pid, ^camera} = key, subscriber} ->
          queue = VideoQueue.push(subscriber.queue, frame)
          {key, send_due(%{subscriber | queue: queue}, pid, camera, state.in_flight_frames)}

        other ->
          other
      end)

    {:noreply, %{state | subscribers: subscribers}}
  end

  def handle_cast({:ack, pid, camera}, state) do
    case state.subscribers do
      %{{^pid, ^camera} => subscriber} ->
        subscriber = %{subscriber | in_flight: max(subscriber.in_flight - 1, 0)}
        subscriber = send_due(subscriber, pid, camera, state.in_flight_frames)
        {:noreply, put_in(state.subscribers[{pid, camera}], subscriber)}

      _subscribers ->
        {:noreply, state}
    end
  end

  def handle_cast(_message, state), do: {:noreply, state}

  @impl GenServer
  def handle_info({:DOWN, monitor, :process, _pid, _reason}, state) do
    subscribers =
      Map.reject(state.subscribers, fn {_key, subscriber} -> subscriber.monitor == monitor end)

    {:noreply, %{state | subscribers: subscribers}}
  end

  def handle_info(_message, state), do: {:noreply, state}

  # The queued frames, in order, while fewer than `in_flight_frames` are unacknowledged.
  defp send_due(%{in_flight: in_flight} = subscriber, _pid, _camera, in_flight_frames)
       when in_flight >= in_flight_frames,
       do: subscriber

  defp send_due(subscriber, pid, camera, in_flight_frames) do
    case VideoQueue.pop(subscriber.queue) do
      {:ok, frame, queue} ->
        send(pid, {:vision_video, camera, frame})

        send_due(
          %{subscriber | queue: queue, in_flight: subscriber.in_flight + 1},
          pid,
          camera,
          in_flight_frames
        )

      :empty ->
        subscriber
    end
  end
end
