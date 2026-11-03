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

  ## Options

    * `:transforms` (required) — a list of maps:

          %{parent: "base_link", child: "stereo_left",
            translation: {x, y, z},          # metres, REP-103: x forward, y left, z up
            rotation: {x, y, z, w}}          # quaternion, defaults to identity

    * `:topic` (`"/tf_static"`), `:interval_ms` (`1000`).

  Published on `/tf_static`, and *republished* every `:interval_ms`.
  Both halves matter.

  Static transforms conventionally rely on TRANSIENT_LOCAL durability
  so a late-joining subscriber receives the latched message;
  `ZenohClient` publishes volatile, so that subscriber would wait for
  ever. Republishing fixes that.

  Republishing on `/tf` instead would not work. A transform on `/tf`
  is *time indexed*: `tf2` stores it against its stamp, interpolates
  between samples, and will not extrapolate past the newest one, so
  any message stamped after the latest transform cannot be transformed
  at all, and consumers such as Nav2's costmaps drop it.

  `/tf_static` has no such window: `tf2` keeps those transforms in a
  separate buffer with no time index, so a lookup at *any* stamp
  succeeds.
  """
  use GenServer

  require Logger

  alias Ros2Zenoh.GeometryMsgs.Msg.{Quaternion, Transform, TransformStamped, Vector3}
  alias Ros2Zenoh.StdMsgs.Msg.Header
  alias Ros2Zenoh.Tf2Msgs.Msg.TFMessage
  alias RosBridge.Timing

  @default_topic "/tf_static"
  @default_interval_ms 1_000

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl GenServer
  def init(opts) do
    state = %{
      topic: Keyword.get(opts, :topic, @default_topic),
      interval_ms: Keyword.get(opts, :interval_ms, @default_interval_ms),
      transforms: opts |> Keyword.fetch!(:transforms) |> Enum.map(&normalise_transform/1)
    }

    Logger.info(
      "#{__MODULE__} publishing #{length(state.transforms)} transform(s) on " <>
        "#{state.topic} every #{state.interval_ms}ms: " <>
        Enum.map_join(state.transforms, ", ", &"#{&1.parent}->#{&1.child}")
    )

    send(self(), :tick)
    {:ok, state}
  end

  @impl GenServer
  def handle_info(:tick, state) do
    stamp = Timing.stamp_from_monotonic(System.monotonic_time(:nanosecond))

    message = %TFMessage{
      transforms:
        Enum.map(state.transforms, fn transform ->
          %TransformStamped{
            header: %Header{stamp: stamp, frame_id: transform.parent},
            child_frame_id: transform.child,
            transform: %Transform{
              translation: transform.translation,
              rotation: transform.rotation
            }
          }
        end)
    }

    RosBridge.ZenohClient.publish(state.topic, TFMessage, message)
    Process.send_after(self(), :tick, state.interval_ms)
    {:noreply, state}
  end

  defp normalise_transform(%{parent: parent, child: child} = transform) do
    {translation_x, translation_y, translation_z} =
      Map.get(transform, :translation, {0.0, 0.0, 0.0})

    {rotation_x, rotation_y, rotation_z, rotation_w} =
      Map.get(transform, :rotation, {0.0, 0.0, 0.0, 1.0})

    %{
      parent: parent,
      child: child,
      translation: %Vector3{
        x: translation_x / 1.0,
        y: translation_y / 1.0,
        z: translation_z / 1.0
      },
      rotation: %Quaternion{
        x: rotation_x / 1.0,
        y: rotation_y / 1.0,
        z: rotation_z / 1.0,
        w: rotation_w / 1.0
      }
    }
  end
end
