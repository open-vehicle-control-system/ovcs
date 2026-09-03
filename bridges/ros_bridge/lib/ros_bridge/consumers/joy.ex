defmodule RosBridge.Consumers.Joy.State do
  defstruct []
end

defmodule RosBridge.Consumers.Joy do
  @moduledoc """
  Subscribes to the ROS 2 `joy` topic via the native-Zenoh client
  (`RosBridge.ZenohClient.subscribe/2`) and translates each
  `sensor_msgs/Joy` sample into Cantastic emitter updates on
  `ros_control0`/`ros_control1`.

  ## Why the axis conversion is defensive

  This is the drive path: axis 0 becomes steering and axis 1 throttle,
  both as signed 32-bit CAN signals. Two things a joystick can legally
  send used to go wrong here, and neither announced itself.

  **An axis outside [-1, 1] flipped the sign.** The value was
  multiplied by 2^31-1 with no clamp, and Cantastic encodes with
  `<<int::little-signed-integer-size(32)>>`, which truncates silently
  rather than raising. An axis of 1.9 became 4_080_218_929, which reads
  back out of a signed 32-bit field as **-214_748_367** — full positive
  lock arriving as a tenth of negative lock. `joy-linux` normally
  normalises to [-1, 1], but a device whose reported range disagrees
  with its actual travel, or a calibration offset, can exceed it.

  **A short `axes` array crashed the consumer.** `Enum.at/2` answers
  `nil` past the end and `Decimal.from_float/1` has no clause for it,
  so a controller with fewer axes — or the empty `axes` that
  `sensor_msgs/Joy` explicitly permits — took the drive path down. It
  restarts, but every frame does it again.

  So `control_value/3` clamps, and a missing axis reads as centre
  rather than as a crash. Centre is the safe reading: it commands
  neither steering nor throttle.
  """
  alias Cantastic.Emitter
  alias Decimal, as: D
  alias Ros2.SensorMsgs.Msg.Joy
  alias RosBridge.Consumers.Joy.State

  require Logger
  use GenServer

  @max_value 2 ** 31 - 1
  @joy_topic "joy"

  @impl true
  def init(_) do
    :ok =
      Emitter.configure(:ovcs, "ros_control0", %{
        parameters_builder_function: :default,
        initial_data: %{
          "control_level" => "joy",
          "direction" => "forward"
        },
        enable: true
      })

    :ok =
      Emitter.configure(:ovcs, "ros_control1", %{
        parameters_builder_function: :default,
        initial_data: %{
          "throttle" => D.new(0),
          "steering" => D.new(0)
        },
        enable: true
      })

    :ok = RosBridge.ZenohClient.subscribe(@joy_topic, Joy)
    {:ok, %State{}}
  end

  @spec start_link(nil) :: :ignore | {:error, any()} | {:ok, pid()}
  def start_link(args) do
    Logger.debug("Starting #{__MODULE__}...")
    GenServer.start_link(__MODULE__, args, name: __MODULE__)
  end

  @doc """
  One joystick axis as a signed 32-bit CAN value.

  `scale` carries the sign convention: steering is inverted, throttle
  is not. A missing axis, or one that is not a number, reads as centre.
  """
  @spec control_value([number()] | nil, non_neg_integer(), integer()) :: Decimal.t()
  def control_value(axes, index, scale) when is_list(axes) do
    axes
    |> Enum.at(index)
    |> clamp()
    |> D.from_float()
    |> D.mult(scale)
  end

  def control_value(_axes, _index, _scale), do: D.new(0)

  # Centre for anything unusable, rather than raising: the drive path
  # staying up and commanding nothing beats it restarting on every
  # frame. `from_float/1` also has no integer clause, so an axis of `0`
  # rather than `0.0` would raise — hence the float conversion here.
  defp clamp(value) when is_float(value), do: value |> max(-1.0) |> min(1.0)
  defp clamp(value) when is_integer(value), do: clamp(value * 1.0)
  defp clamp(_other), do: 0.0

  @impl true
  def handle_info({:ros_message, {_key_expr, %Joy{axes: axes}}}, state) do
    steering = control_value(axes, 0, -@max_value)
    throttle = control_value(axes, 1, @max_value)

    :ok =
      Emitter.update(:ovcs, "ros_control1", fn data ->
        %{data | "steering" => steering, "throttle" => throttle}
      end)

    {:noreply, state}
  end

  # Anything else delivered as `{:ros_message, …}` is a configuration
  # bug (wrong subscribe call somewhere): log loudly rather than
  # silently dropping or matching on the wrong shape.
  def handle_info({:ros_message, {key_expr, message}}, state) do
    Logger.warning("#{__MODULE__} unexpected message on #{key_expr}: #{inspect(message)}")

    {:noreply, state}
  end
end
