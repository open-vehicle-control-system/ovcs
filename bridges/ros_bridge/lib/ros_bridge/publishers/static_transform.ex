defmodule RosBridge.Publishers.StaticTransform do
  @moduledoc """
  Publishes the vehicle's fixed frame relationships on `/tf`.

  Without a transform tree, frame ids in message headers are just
  labels: a consumer knows a depth point sits 1.2 m in front of
  `stereo_left` but not where `stereo_left` is, so it cannot place the
  measurement anywhere. Foxglove's 3D panel reports the frame as
  missing and draws nothing. More importantly for the vehicle, it is
  what turns a camera-relative distance into a body-relative one —
  "1.2 m ahead of the car, 15 cm above the ground" is the form a
  steering decision needs.

  ## Opts

    * `:transforms` (required) — a list of maps:

          %{parent: "base_link", child: "stereo_left",
            translation: {x, y, z},          # metres, REP-103: x fwd, y left, z up
            rotation: {x, y, z, w}}          # quaternion, defaults to identity

    * `:topic` (`"/tf"`), `:interval_ms` (`1000`).

  Published on `/tf` rather than `/tf_static` on purpose. Static
  transforms conventionally rely on TRANSIENT_LOCAL durability so a
  late-joining viewer receives the latched message; `ZenohClient`
  publishes volatile, so that viewer would wait forever. Republishing
  at 1 Hz costs a few hundred bytes a second and always works.
  """
  use GenServer

  require Logger

  alias Ros2.GeometryMsgs.Msg.{Quaternion, Transform, TransformStamped, Vector3}
  alias Ros2.StdMsgs.Msg.Header
  alias Ros2.Tf2Msgs.Msg.TFMessage
  alias RosBridge.Timing

  @default_topic "/tf"
  @default_interval_ms 1_000

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(opts) do
    state = %{
      topic: Keyword.get(opts, :topic, @default_topic),
      interval_ms: Keyword.get(opts, :interval_ms, @default_interval_ms),
      transforms: opts |> Keyword.fetch!(:transforms) |> Enum.map(&normalise/1)
    }

    Logger.info(
      "#{__MODULE__} publishing #{length(state.transforms)} transform(s) on " <>
        "#{state.topic} every #{state.interval_ms}ms: " <>
        Enum.map_join(state.transforms, ", ", &"#{&1.parent}->#{&1.child}")
    )

    send(self(), :tick)
    {:ok, state}
  end

  @impl true
  def handle_info(:tick, state) do
    stamp = Timing.time_message_for(System.monotonic_time(:nanosecond))

    message = %TFMessage{
      transforms:
        Enum.map(state.transforms, fn t ->
          %TransformStamped{
            header: %Header{stamp: stamp, frame_id: t.parent},
            child_frame_id: t.child,
            transform: %Transform{translation: t.translation, rotation: t.rotation}
          }
        end)
    }

    RosBridge.ZenohClient.publish(state.topic, TFMessage, message)
    Process.send_after(self(), :tick, state.interval_ms)
    {:noreply, state}
  end

  defp normalise(%{parent: parent, child: child} = transform) do
    {tx, ty, tz} = Map.get(transform, :translation, {0.0, 0.0, 0.0})
    {rx, ry, rz, rw} = Map.get(transform, :rotation, {0.0, 0.0, 0.0, 1.0})

    %{
      parent: parent,
      child: child,
      translation: %Vector3{x: tx / 1.0, y: ty / 1.0, z: tz / 1.0},
      rotation: %Quaternion{x: rx / 1.0, y: ry / 1.0, z: rz / 1.0, w: rw / 1.0}
    }
  end
end
