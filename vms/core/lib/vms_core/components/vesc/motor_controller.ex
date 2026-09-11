defmodule VmsCore.Components.Vesc.MotorController do
  @moduledoc """
  A motor controller running the VESC firmware, commanded over CAN.

  The throttle actuator for a traction motor behind a VESC: it turns the
  selected commander's request into a motor command on the VESC's
  extended CAN frames, and publishes the motor telemetry the VESC
  reports back. See `libraries/ovcs_can/priv/can/components/vesc/`.

  ## Three commands, one at a time

  The VESC has several control modes and applies the one it was last
  told. Exactly one command frame is emitted at any moment; which one
  depends on who commands the vehicle:

    * **No source** (a control level that commands nothing) sends
      `vesc_set_current` at zero: no torque, the motor spins freely.
      This is the release, and it is also what the VESC falls back to
      when no command arrives within its timeout.
    * **A hand** (any source not in `:linear_sources`) sends
      `vesc_set_duty`, the open-loop mode that behaves like a trigger
      on a conventional ESC. The request goes through the same dead
      zone, feel curve and start offset as `Traxxas.Throttle`, with the
      same options; a released trigger sends zero duty, which the VESC
      turns into a light drag brake.
    * **A physical velocity** (a source in `:linear_sources`, such as
      `OVCS.RosVelocityCommand`) sends `vesc_set_rpm`: the request in
      [-1, 1] is a fraction of `:max_rotation_per_minute`, converted to
      electrical rpm, and the VESC's speed loop holds it under load. Below the
      VESC's *minimum speed-PID erpm* the loop is off and the VESC
      holds zero duty instead, a passive brake: a zero request brakes
      to a standstill, which is what a planner that stopped means, but
      so does any request under that minimum. It must be set below the
      slowest velocity a commander sends; the firmware default of 900
      erpm is a walking pace on a small vehicle. Negative requests
      reverse, so a planner may plan in reverse.

  ## Telemetry

  `vesc_status` carries the signed electrical rpm and the motor
  current, `vesc_status_5` the input voltage. They are published as
  `:rotation_per_minute` (mechanical, signed), `:motor_current` and
  `:input_voltage`, nil while the status frame is not arriving — the
  VESC is off, unpowered or not configured to send status.

  What the motor's rotation means for the vehicle is not this
  component's to know: the gearing to the wheels and the wheel size are
  the vehicle's kinematics, and `OVCS.VehicleMotion` applies them to
  whichever shaft it is given — this motor, or a pulse sensor
  elsewhere in the driveline.

  ## Options

    * `:selected_control_level_source` — the manager that names the
      throttle source, `Managers.ControlLevel`.
    * `:linear_sources` — commanders whose request is a physical
      quantity; they get the rpm mode and skip the feel curve.
    * `:max_rotation_per_minute` — mechanical motor rpm at a linear
      request of 1. The composer derives it from the speed the linear
      commanders normalise against and the vehicle's kinematics, so the
      gearing is declared once, next to `VehicleMotion`'s.
    * `:pole_pairs` — of the motor: electrical rpm is mechanical rpm
      times this. A 4-pole motor has 2.
    * `:deadzone`, `:expo`, `:start_offset`, `:max_throttle`,
      `:max_reverse` — the feel curve for hands, as documented on
      `Traxxas.Throttle`. They shape the duty command only; the caps
      do not apply to a velocity, which `:max_rotation_per_minute` already bounds.

  The VESC itself must have id 1, the CAN bitrate of the bus, status
  messages 1 and 5 enabled at 50 Hz, a command timeout longer than the
  emitters' 20 ms period, and a minimum speed-PID erpm below the
  slowest velocity in use. Its own current, rpm and duty limits stay in
  force below whatever is commanded here. `docs/vesc_drivetrain.md`
  has the settings.
  """
  use GenServer
  alias Decimal, as: D
  alias OvcsBus, as: Bus
  alias Cantastic.{Emitter, Frame, Receiver, ReceivedFrameWatcher, Signal}
  alias VmsCore.Components.Traxxas.Throttle

  @loop_period 10
  @network :ovcs
  @set_duty "vesc_set_duty"
  @set_current "vesc_set_current"
  @set_rpm "vesc_set_rpm"
  @status "vesc_status"
  @status_5 "vesc_status_5"
  @zero D.new(0)
  @one D.new(1)
  @release {@set_current, %{"current" => @zero}}

  def start_link(args) do
    GenServer.start_link(__MODULE__, args, name: __MODULE__)
  end

  @impl true
  def init(
        %{
          selected_control_level_source: selected_control_level_source,
          max_rotation_per_minute: max_rotation_per_minute,
          pole_pairs: pole_pairs
        } = args
      ) do
    Bus.subscribe("messages")
    # Errors too: the watcher's missing-frame events are what turn the
    # telemetry back to nil when the VESC goes quiet.
    :ok = Receiver.subscribe(self(), @network, [@status, @status_5], %{errors: true})
    :ok = ReceivedFrameWatcher.enable(@network, @status)

    # All three command emitters exist from the start, none enabled:
    # the first tick enables the one for the selected source.
    :ok = configure_emitter(@set_duty, %{"duty" => @zero})
    :ok = configure_emitter(@set_current, %{"current" => @zero})
    :ok = configure_emitter(@set_rpm, %{"erpm" => 0})

    {:ok, timer} = :timer.send_interval(@loop_period, :loop)

    {:ok,
     %{
       loop_timer: timer,
       selected_control_level_source: selected_control_level_source,
       linear_sources: Map.get(args, :linear_sources, []),
       curve: Throttle.curve(args),
       erpm_per_request: erpm_per_request(max_rotation_per_minute, pole_pairs),
       pole_pairs: pole_pairs,
       # Starts nil: nothing commands this actuator until the manager
       # names a source. The manager's default level does that on its
       # first tick.
       requested_throttle_source: nil,
       requested_throttle: @zero,
       # No command has been sent yet: even the release has to enable
       # its emitter once.
       command: nil,
       # Unknown until the VESC reports, see the moduledoc.
       erpm: nil,
       motor_current: nil,
       input_voltage: nil
     }}
  end

  @impl true
  def handle_info(:loop, state) do
    state =
      state
      |> apply_command()
      |> emit_metrics()

    {:noreply, state}
  end

  def handle_info(
        %Bus.Message{
          name: :requested_throttle_source,
          value: requested_throttle_source,
          source: source
        },
        state
      )
      when source == state.selected_control_level_source do
    # Zero on the way to a level that commands nothing, for the reason
    # `Traxxas.Throttle` gives: with no source no request message
    # matches, and the last request would otherwise be held.
    requested = if is_nil(requested_throttle_source), do: @zero, else: state.requested_throttle

    {:noreply,
     %{
       state
       | requested_throttle_source: requested_throttle_source,
         requested_throttle: requested
     }}
  end

  def handle_info(
        %Bus.Message{name: :requested_throttle, value: requested_throttle, source: source},
        state
      )
      when source == state.requested_throttle_source do
    {:noreply, %{state | requested_throttle: requested_throttle}}
  end

  def handle_info(%Bus.Message{}, state) do
    {:noreply, state}
  end

  def handle_info({:handle_frame, %Frame{name: @status, signals: signals}}, state) do
    %{"erpm" => %Signal{value: erpm}, "motor_current" => %Signal{value: motor_current}} = signals
    {:noreply, %{state | erpm: erpm, motor_current: motor_current}}
  end

  def handle_info({:handle_frame, %Frame{name: @status_5, signals: signals}}, state) do
    %{"input_voltage" => %Signal{value: input_voltage}} = signals
    {:noreply, %{state | input_voltage: input_voltage}}
  end

  def handle_info({:handle_missing_frame, @network, @status}, state) do
    {:noreply, %{state | erpm: nil, motor_current: nil}}
  end

  def handle_info({:handle_missing_frame, @network, _frame_name}, state) do
    {:noreply, state}
  end

  # `command` holds what was last written to the VESC, not what was
  # last requested: the same request maps to a different frame
  # depending on its source, so a switch of source at an unchanged
  # request still has to reach the bus.
  defp apply_command(state) do
    command = command(state)

    case state.command == command do
      true ->
        state

      false ->
        {frame_name, data} = command
        :ok = Emitter.update(@network, frame_name, fn _ -> data end)

        case state.command do
          {^frame_name, _} -> :ok
          {previous_frame_name, _} -> switch_emitter(previous_frame_name, frame_name)
          nil -> Emitter.enable(@network, frame_name)
        end

        Bus.broadcast("messages", %Bus.Message{
          name: :throttle,
          value: throttle(state),
          source: __MODULE__
        })

        %{state | command: command}
    end
  end

  # The update above is a call and the enable a cast on the same
  # emitter, so the new frame carries the new data from its first
  # emission. Disabling first leaves the VESC without a command for a
  # tick at most, far inside its timeout.
  defp switch_emitter(previous_frame_name, frame_name) do
    Emitter.disable(@network, previous_frame_name)
    Emitter.enable(@network, frame_name)
  end

  @doc """
  The command frame and data for a state: `{frame_name, data}`. The
  release when no source is selected, a duty for a hand, an electrical
  rpm for a physical velocity.
  """
  def command(%{requested_throttle_source: nil}), do: @release

  def command(state) do
    if state.requested_throttle_source in state.linear_sources do
      {@set_rpm, %{"erpm" => erpm_setpoint(state.requested_throttle, state.erpm_per_request)}}
    else
      {@set_duty, %{"duty" => Throttle.shape(state.requested_throttle, false, state.curve)}}
    end
  end

  # The normalised command in [-1, 1] for the dashboard: the duty for a
  # hand, the fraction of the maximum rpm for a velocity, zero for none.
  defp throttle(%{requested_throttle_source: nil}), do: @zero

  defp throttle(state) do
    if state.requested_throttle_source in state.linear_sources do
      state.requested_throttle |> D.max(D.negate(@one)) |> D.min(@one)
    else
      Throttle.shape(state.requested_throttle, false, state.curve)
    end
  end

  @doc false
  def erpm_setpoint(requested, erpm_per_request) do
    requested
    |> D.max(D.negate(@one))
    |> D.min(@one)
    |> D.mult(erpm_per_request)
    |> D.round()
    |> D.to_integer()
  end

  # Electrical rpm at a request of 1.
  @doc false
  def erpm_per_request(max_rotation_per_minute, pole_pairs) do
    D.from_float(1.0 * max_rotation_per_minute * pole_pairs)
  end

  # The mechanical rpm of the motor, signed like the erpm it comes from.
  @doc false
  def rotation_per_minute(nil, _pole_pairs), do: nil

  def rotation_per_minute(erpm, pole_pairs) do
    erpm |> D.new() |> D.div(pole_pairs) |> D.round(1)
  end

  defp emit_metrics(state) do
    Bus.broadcast("messages", %Bus.Message{
      name: :rotation_per_minute,
      value: rotation_per_minute(state.erpm, state.pole_pairs),
      source: __MODULE__
    })

    Bus.broadcast("messages", %Bus.Message{
      name: :motor_current,
      value: state.motor_current,
      source: __MODULE__
    })

    Bus.broadcast("messages", %Bus.Message{
      name: :input_voltage,
      value: state.input_voltage,
      source: __MODULE__
    })

    state
  end

  defp configure_emitter(frame_name, initial_data) do
    Emitter.configure(@network, frame_name, %{
      parameters_builder_function: :default,
      initial_data: initial_data,
      enable: false
    })
  end
end
