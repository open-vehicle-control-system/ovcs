defmodule VmsCore.Components.OVCS.VehicleMotion do
  @moduledoc """
  Emits the vehicle's own motion on `vehicle_motion` (`0x60B`) for
  consumers that integrate it — the ROS bridge's odometry publisher
  first of all.

  ## The sign comes from the command, the magnitude from the sensor

  A hall sensor pulsing once per shaft turn measures |speed| and
  cannot know which way the shaft turns. The VMS knows what it
  commanded: this component follows the throttle request the control
  level manager selected, the same way the actuators do, and stamps
  the speed with its sign. A zero throttle keeps the last non-zero
  sign — a coasting vehicle still moves the way it was last driven.

  The angle is the commanded steering, not a measured one: the servo
  has no feedback. It is the selected `:requested_steering` in
  `[-1, 1]` scaled by `:steering_limit`, and `:steering_sign` converts
  from the servo's convention back to REP-103's positive-left, undoing
  the sign the command path applied on the way in.

  ## Unknown is not zero

  `:speed` on the bus is nil while the pulse counter frame is dead.
  The frame then carries `speed_valid: false` and a zero speed, and an
  integrator must stop rather than hold — the same rule the control
  level manager applies to mode changes.

  `sequence` increments once per fresh speed sample. The emitter
  retransmits on a timer, so a frame arriving on time only proves this
  process is alive; a sequence that stops advancing tells the consumer
  the data went stale even while `speed_valid` still reads true.

  ## Options

    * `:speed_source` — publishes `:speed` in km/h (`PulseSpeedSensor`).
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
          speed_source: speed_source,
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
       speed_source: speed_source,
       selected_control_level_source: selected_control_level_source,
       steering_factor: D.mult(D.from_float(1.0 * steering_limit), steering_sign),
       requested_throttle_source: nil,
       requested_steering_source: nil,
       direction_sign: 1,
       requested_steering: @zero,
       speed: nil,
       sequence: 0
     }}
  end

  @impl true
  def handle_info(:loop, state) do
    :ok =
      Emitter.update(:ovcs, @frame_name, fn data ->
        %{
          data
          | "speed" => signed_speed_m_s(state.speed, state.direction_sign),
            "steering_angle" => steering_angle(state.requested_steering, state.steering_factor),
            "speed_valid" => not is_nil(state.speed),
            "sequence" => state.sequence
        }
      end)

    {:noreply, state}
  end

  def handle_info(%Bus.Message{name: :speed, value: speed, source: source}, state)
      when source == state.speed_source do
    sequence = if is_nil(speed), do: state.sequence, else: rem(state.sequence + 1, 256)
    {:noreply, %{state | speed: speed, sequence: sequence}}
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

  # The bus speed is km/h, the frame is m/s. A nil speed encodes as
  # zero; `speed_valid` is what tells the consumer not to read it.
  @doc false
  def signed_speed_m_s(nil, _sign), do: @zero

  def signed_speed_m_s(speed, sign) do
    speed |> D.div(D.new("3.6")) |> D.mult(sign) |> D.round(3)
  end

  @doc false
  def steering_angle(requested_steering, steering_factor) do
    requested_steering |> D.mult(steering_factor) |> D.round(3)
  end
end
