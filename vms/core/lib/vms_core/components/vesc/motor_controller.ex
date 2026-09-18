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
      `set_current` at zero: no torque, the motor spins freely. This is
      the release, and it is also what the VESC falls back to when no
      command arrives within its timeout.
    * **A hand** (any source not in `:linear_sources`) sends
      `set_duty`, the open-loop mode that behaves like a trigger on a
      conventional ESC. The request goes through the same dead zone,
      feel curve and start offset as `Traxxas.Throttle`, with the same
      options; a released trigger sends zero duty, which the VESC turns
      into a drag brake.
    * **A physical velocity** (a source in `:linear_sources`, such as
      `OVCS.RosVelocityCommand`) sends `set_rpm`: the request in
      [-1, 1] is a fraction of `:max_rotation_per_minute`, converted to
      electrical rpm, and the VESC's speed loop holds it under load.
      Negative requests reverse, so a planner may plan in reverse.

  A velocity of exactly zero is not sent as an rpm of zero. The VESC
  only starts its speed loop for a setpoint above its *minimum
  speed-PID erpm*; below it a running motor holds zero duty, a passive
  brake, but a released motor stays released and a small setpoint
  never starts it. Zero goes out as `set_duty` at zero instead, which
  brakes from any state and leaves the motor running for the next
  setpoint. Any other velocity under that minimum is at the mercy of
  the setting, so it must sit below the slowest velocity a commander
  sends; the firmware default of 900 erpm is a walking pace on a small
  vehicle.

  ## Telemetry

  `status` carries the signed electrical rpm and the motor current,
  `status_5` the input voltage. They are published as
  `:rotation_per_minute` (mechanical, signed), `:motor_current` and
  `:input_voltage`, once per frame received — a message per sample, so
  a consumer integrating the rotation can tell a fresh value from a
  held one — and as nil the moment the frame watcher declares the
  frame missing: the VESC is off, unpowered or not configured to send
  status.

  What the motor's rotation means for the vehicle is not this
  component's to know: the gearing to the wheels and the wheel size are
  the vehicle's kinematics, and `OVCS.VehicleMotion` applies them to
  whichever shaft it is given — this motor, or a pulse sensor
  elsewhere in the driveline.

  ## Frames

  The frame names follow the process name the way the generic
  controller's do: `Vms.Vesc` reads and emits `vesc_set_duty`,
  `vesc_set_current`, `vesc_set_rpm`, `vesc_status` and
  `vesc_status_5`. The vehicle topology declares those five frames on
  `:network`, each wrapping the matching `*_signals.yml` with the
  VESC's id in the low identifier byte. A second VESC is a second
  process name, a second set of wrappers and another id byte.

  ## Options

    * `:process_name` — the name this process registers under, the
      source of its bus messages, and the prefix of its frame names.
    * `:network` — the CAN network the VESC sits on, as named in the
      vehicle's topology YAML.
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
      do not apply to a velocity, which `:max_rotation_per_minute`
      already bounds.

  The VESC itself must have the id the wrappers use, the CAN bitrate
  of the bus, status messages 1 and 5 enabled at 50 Hz, a command
  timeout longer than the emitters' 20 ms period, and a minimum
  speed-PID erpm below the slowest velocity in use. Its own current,
  rpm and duty limits stay in force below whatever is commanded here.
  `docs/vesc_drivetrain.md` has the settings.
  """
  use GenServer
  alias Decimal, as: D
  alias OvcsBus, as: Bus
  alias Cantastic.{Emitter, Frame, Receiver, ReceivedFrameWatcher, Signal}
  alias VmsCore.Components.Traxxas.Throttle

  @loop_period 10
  @frame_suffixes [:set_duty, :set_current, :set_rpm, :status, :status_5]
  @zero D.new(0)

  def start_link(%{process_name: process_name} = args) do
    GenServer.start_link(__MODULE__, args, name: process_name)
  end

  @impl true
  def init(
        %{
          process_name: process_name,
          network: network,
          selected_control_level_source: selected_control_level_source,
          max_rotation_per_minute: max_rotation_per_minute,
          pole_pairs: pole_pairs
        } = args
      ) do
    frames = frame_names(process_name)

    Bus.subscribe("messages")
    # Errors too: the watcher's missing-frame events are what turn the
    # telemetry back to nil when the VESC goes quiet. Both status
    # frames are watched, so the voltage does not outlive the VESC.
    :ok = Receiver.subscribe(self(), network, [frames.status, frames.status_5], %{errors: true})
    :ok = ReceivedFrameWatcher.enable(network, frames.status)
    :ok = ReceivedFrameWatcher.enable(network, frames.status_5)

    # All three command emitters exist from the start, none enabled:
    # the first tick enables the one for the selected source.
    :ok = configure_emitter(network, frames.set_duty, %{"duty" => @zero})
    :ok = configure_emitter(network, frames.set_current, %{"current" => @zero})
    :ok = configure_emitter(network, frames.set_rpm, %{"erpm" => 0})

    {:ok, timer} = :timer.send_interval(@loop_period, :loop)

    {:ok,
     %{
       loop_timer: timer,
       process_name: process_name,
       network: network,
       frames: frames,
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
       command: nil
     }}
  end

  @impl true
  def handle_info(:loop, state) do
    {:noreply, apply_command(state)}
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

  # Converted and published as the frame arrives, not on the tick: the
  # constant is fixed and the value only changes with a frame.
  def handle_info({:handle_frame, %Frame{name: name, signals: signals}}, state)
      when name == state.frames.status do
    %{"erpm" => %Signal{value: erpm}, "motor_current" => %Signal{value: motor_current}} = signals
    broadcast(state, :rotation_per_minute, rotation_per_minute(erpm, state.pole_pairs))
    broadcast(state, :motor_current, motor_current)
    {:noreply, state}
  end

  def handle_info({:handle_frame, %Frame{name: name, signals: signals}}, state)
      when name == state.frames.status_5 do
    %{"input_voltage" => %Signal{value: input_voltage}} = signals
    broadcast(state, :input_voltage, input_voltage)
    {:noreply, state}
  end

  def handle_info({:handle_missing_frame, network, name}, state)
      when network == state.network and name == state.frames.status do
    broadcast(state, :rotation_per_minute, nil)
    broadcast(state, :motor_current, nil)
    {:noreply, state}
  end

  def handle_info({:handle_missing_frame, network, name}, state)
      when network == state.network and name == state.frames.status_5 do
    broadcast(state, :input_voltage, nil)
    {:noreply, state}
  end

  def handle_info({:handle_missing_frame, _network, _frame_name}, state) do
    {:noreply, state}
  end

  # `command` holds what was last written to the VESC, not what was
  # last requested: the same request maps to a different frame
  # depending on its source, so a switch of source at an unchanged
  # request still has to reach the bus.
  defp apply_command(state) do
    {frame, data, throttle} = command(state)
    command = {frame, data}

    case state.command == command do
      true ->
        state

      false ->
        frame_name = state.frames[frame]
        :ok = Emitter.update(state.network, frame_name, fn _ -> data end)

        case state.command do
          {^frame, _} -> :ok
          {previous, _} -> switch_emitter(state.network, state.frames[previous], frame_name)
          nil -> Emitter.enable(state.network, frame_name)
        end

        broadcast(state, :throttle, throttle)
        %{state | command: command}
    end
  end

  # The update above is a call and the enable a cast on the same
  # emitter, so the new frame carries the new data from its first
  # emission. Disabling first leaves the VESC without a command for a
  # tick at most, far inside its timeout.
  defp switch_emitter(network, previous_frame_name, frame_name) do
    Emitter.disable(network, previous_frame_name)
    Emitter.enable(network, frame_name)
  end

  @doc """
  The command for a state: `{frame, data, throttle}`, where `frame` is
  one of `:set_current`, `:set_duty` and `:set_rpm`, `data` its
  signals, and `throttle` the normalised command in [-1, 1] the
  dashboard shows — the duty for a hand, the fraction of the maximum
  rpm for a velocity, zero for none.
  """
  def command(%{requested_throttle_source: nil}) do
    {:set_current, %{"current" => @zero}, @zero}
  end

  def command(state) do
    if state.requested_throttle_source in state.linear_sources do
      requested = Throttle.clamp(state.requested_throttle)

      if D.eq?(requested, @zero) do
        {:set_duty, %{"duty" => @zero}, @zero}
      else
        {:set_rpm, %{"erpm" => erpm_setpoint(requested, state.erpm_per_request)}, requested}
      end
    else
      duty = Throttle.shape(state.requested_throttle, false, state.curve)
      {:set_duty, %{"duty" => duty}, duty}
    end
  end

  @doc false
  def erpm_setpoint(requested, erpm_per_request) do
    requested |> D.mult(erpm_per_request) |> D.round() |> D.to_integer()
  end

  # Electrical rpm at a request of 1.
  @doc false
  def erpm_per_request(max_rotation_per_minute, pole_pairs) do
    D.from_float(1.0 * max_rotation_per_minute * pole_pairs)
  end

  # The mechanical rpm of the motor, signed like the erpm it comes from.
  @doc false
  def rotation_per_minute(erpm, pole_pairs) do
    erpm |> D.new() |> D.div(pole_pairs) |> D.round(1)
  end

  @doc false
  def frame_names(process_name) do
    prefix = Macro.underscore(process_name) |> String.split("/") |> List.last()
    Map.new(@frame_suffixes, fn suffix -> {suffix, "#{prefix}_#{suffix}"} end)
  end

  defp broadcast(state, name, value) do
    Bus.broadcast("messages", %Bus.Message{name: name, value: value, source: state.process_name})
  end

  defp configure_emitter(network, frame_name, initial_data) do
    Emitter.configure(network, frame_name, %{
      parameters_builder_function: :default,
      initial_data: initial_data,
      enable: false
    })
  end
end
