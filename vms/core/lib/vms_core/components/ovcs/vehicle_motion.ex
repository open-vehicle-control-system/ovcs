defmodule VmsCore.Components.OVCS.VehicleMotion do
  @moduledoc """
  The vehicle's own motion: its speed from the rotation of a shaft in
  the driveline, published on the bus as `:speed` and emitted on
  `vehicle_motion` (`0x60B`) for consumers that integrate it — the ROS
  bridge's odometry publisher first of all.

  ## The kinematics live here

  No sensor knows the vehicle's speed. A pulse sensor knows how fast
  its shaft turns, a motor controller how fast its motor turns; what
  either means in metres per second depends on the gearing between that
  shaft and the wheels and on the size of the wheels. Those are
  properties of the vehicle, so this is where they are declared and
  applied:

      wheel rpm = rotation_per_minute / rotation_to_wheel_ratio
      speed     = wheel rpm / 60 · 2π · wheel_radius

  `:speed` is published in km/h, the unit every other `:speed` on the
  bus uses, and `:wheel_rotation_per_minute` alongside it. The
  standstill gate in `Managers.ControlLevel` reads the speed from here.

  ## The sign

  A switch on a shaft measures |rotation| and cannot know which way the
  shaft turns. The VMS knows what it commanded: with
  `rotation_signed: false` this component follows the throttle request
  the control level manager selected, the same way the actuators do,
  and stamps the speed with its sign. A zero throttle keeps the last
  non-zero sign — a coasting vehicle still moves the way it was last
  driven. A source that reads a signed rotation off a motor controller
  declares `rotation_signed: true` and its sign is used as is.

  The angle is the commanded steering, not a measured one: the servo
  has no feedback. It is the selected `:requested_steering` in
  `[-1, 1]` scaled by `:steering_limit`, and `:steering_sign` converts
  from the servo's convention back to REP-103's positive-left, undoing
  the sign the command path applied on the way in.

  ## Unknown is not zero

  The rotation source publishes nil while its frame is dead, and the
  speed is nil in turn. The frame then carries `speed_valid: false` and
  a zero speed, and an integrator must stop rather than hold — the
  same rule the control level manager applies to mode changes.

  `sequence` increments once per fresh rotation sample. The emitter
  retransmits on a timer, so a frame arriving on time only proves this
  process is alive; a sequence that stops advancing tells the consumer
  the data went stale even while `speed_valid` still reads true.

  ## Options

    * `:rotation_source` — publishes `:rotation_per_minute` of a shaft
      in the driveline (`PulseRotationSensor`, `Vesc.MotorController`).
    * `:rotation_to_wheel_ratio` — turns of that shaft per wheel turn.
      One when the shaft is the wheel itself.
    * `:rotation_signed` — `true` when the source's rotation already
      carries the direction of travel. Default `false`.
    * `:wheel_radius` — metres, from the vehicle's `geometry/0`.
    * `:selected_control_level_source` — names the throttle and
      steering sources (`Managers.ControlLevel`).
    * `:steering_limit` — radians at full lock, from `geometry/0`.
    * `:steering_sign` — `1` or `-1`, matching the sign given to
      `RosVelocityCommand`. Default `1`.
  """
  use GenServer
  alias Cantastic.Emitter
  alias Decimal, as: D
  alias OvcsBus, as: Bus

  @loop_period 50
  @frame_name "vehicle_motion"
  @zero D.new(0)

  def start_link(args) do
    GenServer.start_link(__MODULE__, args, name: __MODULE__)
  end

  @impl true
  def init(
        %{
          rotation_source: rotation_source,
          rotation_to_wheel_ratio: rotation_to_wheel_ratio,
          wheel_radius: wheel_radius,
          selected_control_level_source: selected_control_level_source,
          steering_limit: steering_limit
        } = args
      ) do
    steering_sign = Map.get(args, :steering_sign, 1)

    unless steering_sign in [1, -1] do
      raise ArgumentError, "steering_sign must be 1 or -1, got #{inspect(steering_sign)}"
    end

    :ok =
      Emitter.configure(:ovcs, @frame_name, %{
        parameters_builder_function: :default,
        initial_data: %{
          "speed" => @zero,
          "steering_angle" => @zero,
          "speed_valid" => false,
          "sequence" => 0
        },
        enable: true
      })

    Bus.subscribe("messages")
    {:ok, timer} = :timer.send_interval(@loop_period, :loop)

    {:ok,
     %{
       loop_timer: timer,
       rotation_source: rotation_source,
       rotation_signed: Map.get(args, :rotation_signed, false),
       rotation_to_wheel_ratio: D.from_float(1.0 * rotation_to_wheel_ratio),
       speed_factor: speed_factor(rotation_to_wheel_ratio, wheel_radius),
       selected_control_level_source: selected_control_level_source,
       steering_factor: D.mult(D.from_float(1.0 * steering_limit), steering_sign),
       requested_throttle_source: nil,
       requested_steering_source: nil,
       direction_sign: 1,
       requested_steering: @zero,
       # Unknown until the source reports, see the moduledoc.
       rotation_per_minute: nil,
       sequence: 0
     }}
  end

  @impl true
  def handle_info(:loop, state) do
    speed = speed_km_h(state)

    :ok =
      Emitter.update(:ovcs, @frame_name, fn data ->
        %{
          data
          | "speed" => speed_m_s(speed),
            "steering_angle" => steering_angle(state.requested_steering, state.steering_factor),
            "speed_valid" => not is_nil(speed),
            "sequence" => state.sequence
        }
      end)

    Bus.broadcast("messages", %Bus.Message{name: :speed, value: speed, source: __MODULE__})

    Bus.broadcast("messages", %Bus.Message{
      name: :wheel_rotation_per_minute,
      value: wheel_rotation_per_minute(state),
      source: __MODULE__
    })

    {:noreply, state}
  end

  def handle_info(
        %Bus.Message{name: :rotation_per_minute, value: rotation_per_minute, source: source},
        state
      )
      when source == state.rotation_source do
    sequence =
      if is_nil(rotation_per_minute), do: state.sequence, else: rem(state.sequence + 1, 256)

    {:noreply, %{state | rotation_per_minute: rotation_per_minute, sequence: sequence}}
  end

  # The same source-following the actuators do: the manager names the
  # commanders, and only their messages are read.
  def handle_info(
        %Bus.Message{name: :requested_throttle_source, value: value, source: source},
        state
      )
      when source == state.selected_control_level_source do
    {:noreply, %{state | requested_throttle_source: value}}
  end

  def handle_info(
        %Bus.Message{name: :requested_steering_source, value: value, source: source},
        state
      )
      when source == state.selected_control_level_source do
    {:noreply, %{state | requested_steering_source: value}}
  end

  def handle_info(
        %Bus.Message{name: :requested_throttle, value: requested_throttle, source: source},
        state
      )
      when source == state.requested_throttle_source do
    {:noreply,
     %{state | direction_sign: direction_sign(requested_throttle, state.direction_sign)}}
  end

  def handle_info(
        %Bus.Message{name: :requested_steering, value: requested_steering, source: source},
        state
      )
      when source == state.requested_steering_source do
    {:noreply, %{state | requested_steering: requested_steering}}
  end

  def handle_info(%Bus.Message{}, state) do
    {:noreply, state}
  end

  # Zero keeps the last sign: releasing the trigger does not mean the
  # vehicle changed direction, it means it is coasting.
  @doc false
  def direction_sign(requested_throttle, last_sign) do
    cond do
      D.gt?(requested_throttle, @zero) -> 1
      D.lt?(requested_throttle, @zero) -> -1
      true -> last_sign
    end
  end

  # km/h per rpm of the sensed shaft, fixed at init: one wheel
  # circumference per `rotation_to_wheel_ratio` turns, sixty of them an
  # hour... per minute, a thousand metres to the kilometre.
  @doc false
  def speed_factor(rotation_to_wheel_ratio, wheel_radius) do
    wheel_circumference = 2 * :math.pi() * wheel_radius
    D.from_float(wheel_circumference * 60 / 1000 / rotation_to_wheel_ratio)
  end

  # Signed km/h, or nil while the rotation is unknown. A signed source
  # already carries the direction; an unsigned one gets the command's.
  @doc false
  def speed_km_h(%{rotation_per_minute: nil}), do: nil

  def speed_km_h(state) do
    sign = if state.rotation_signed, do: 1, else: state.direction_sign
    state.rotation_per_minute |> D.mult(state.speed_factor) |> D.mult(sign) |> D.round(2)
  end

  @doc false
  def wheel_rotation_per_minute(%{rotation_per_minute: nil}), do: nil

  def wheel_rotation_per_minute(state) do
    state.rotation_per_minute |> D.div(state.rotation_to_wheel_ratio) |> D.round(1)
  end

  # The bus speed is km/h, the frame is m/s. A nil speed encodes as
  # zero; `speed_valid` is what tells the consumer not to read it.
  @doc false
  def speed_m_s(nil), do: @zero

  def speed_m_s(speed) do
    speed |> D.div(D.new("3.6")) |> D.round(3)
  end

  @doc false
  def steering_angle(requested_steering, steering_factor) do
    requested_steering |> D.mult(steering_factor) |> D.round(3)
  end
end
