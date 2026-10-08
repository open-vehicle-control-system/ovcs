defmodule VmsCore.Components.Vesc.MotorController do
  @moduledoc """
  A motor controller running the VESC firmware, commanded over CAN.

  The throttle actuator for a traction motor behind a VESC: it turns the
  selected commander's request into a motor command on the VESC's
  extended CAN frames, and publishes the motor telemetry the VESC
  reports back. See `libraries/ovcs_can/priv/can/components/vesc/`.

  ## One command at a time

  The VESC has several control modes and applies the one it was last
  told. Exactly one command frame is emitted at any moment; which one
  depends on who commands the vehicle:

    * **No source** (a control level that commands nothing) sends
      `set_current` at zero: no torque, the motor spins freely. This is
      the release, and it is also what the VESC falls back to when no
      command arrives within its timeout.
    * **A hand** (any source not in `:linear_sources`) drives the motor
      the way `:hand_control` says, see below. The request arrives
      already shaped by the hand's `OVCS.InputCurve` and is only scaled
      by the caps. With a gear source, see below, a hand drives through
      the selected gear.
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

  ## Duty or current for hands

  `:hand_control` picks how a hand's request reaches the motor:

    * `:duty` (the default) sends `set_duty`, a fraction of the pack
      voltage, like a trigger on a conventional ESC. A duty behaves
      like a speed target: easing the request below what the motor's
      speed needs brakes it down, and without gears a released
      trigger's zero duty is a drag brake.
    * `:current` sends `set_current`, from `:min_current` at the
      smallest request to `:max_current` at a full one: a torque, like
      a car's accelerator. Easing the request pushes less and never
      brakes, and zero coasts. Braking is the request's negative side,
      with gears. `:min_current` sits just under what the vehicle needs
      to start rolling, so the request's travel is spent moving it
      rather than fighting static friction.

  ## Gears for hands

  With `:selected_gear_source` (`Managers.Gear`) a hand's request no
  longer carries the direction: the gear does, the way a car's does.

    * A positive request drives in the selected gear: forward in
      `:drive`, reverse in `:reverse`, capped by `:max_throttle` and
      `:max_reverse` respectively. In `:neutral` or `:parking`, or
      before a gear is known, it releases the motor.
    * A negative request brakes, in every gear: `set_current_brake`,
      a braking current that opposes the rotation whichever way the
      motor turns and never drives it the other way. It is the request's
      magnitude times `:max_brake_current`.
    * A released trigger releases the motor: it coasts.

  A velocity ignores the gear: its sign is the direction of travel, and
  the planner may plan in reverse.

  ## Telemetry

  Each time the command changes, `:command` names it — `release`,
  `brake`, `duty`, `current` or `speed` — with `:throttle`, the
  normalised drive command, `:drive_current`, the current driving the
  motor, and `:brake_current`, zero unless braking. At start, the
  settings: `:hand_control` (`duty` or `current`), `:min_current` and
  `:max_current` (nil with `duty`), and `:max_brake_current`.

  `status` carries the erpm and the motor current, `status_5` the
  tachometer and the input voltage. The rotation comes from one of the
  two, see `:rotation_from`. The tachometer is also published as
  `:revolutions`, the motor's signed mechanical turns since the VESC
  started: a distance, for a consumer that integrates position without
  the lag of the rate's window. They are published as `:rotation_per_minute`
  (mechanical, signed) with the `:direction` it gives, `:motor_current`
  and `:input_voltage`, once per frame received — a message per sample,
  so a consumer integrating the rotation can tell a fresh value from a
  held one — and as nil the moment the frame watcher declares the frame
  missing: the VESC is off, unpowered or not configured to send status.

  What the motor's rotation means for the vehicle is not this
  component's to know: the gearing to the wheels and the wheel size are
  the vehicle's kinematics, and `OVCS.VehicleMotion` applies them to
  whichever shaft it is given — this motor, or a pulse sensor
  elsewhere in the driveline.

  ## Frames

  The frame names follow the process name the way the generic
  controller's do: `Vms.Vesc` reads and emits `vesc_set_duty`,
  `vesc_set_current`, `vesc_set_rpm`, `vesc_status` and
  `vesc_status_5`, and `vesc_set_current_brake` with a gear source. The
  vehicle topology declares those frames on `:network`, each wrapping the matching `*_signals.yml` with the
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
      quantity; they get the rpm mode and skip the caps.
    * `:max_rotation_per_minute` — mechanical motor rpm at a linear
      request of 1. The composer derives it from the speed the linear
      commanders normalise against and the vehicle's kinematics, so the
      gearing is declared once, next to `VehicleMotion`'s.
    * `:pole_pairs` — of the motor: electrical rpm is mechanical rpm
      times this. A 4-pole motor has 2.
    * `:rotation_from` — `:tachometer` (default) differences the
      tachometer, a signed count of 6 steps per electrical turn, over
      a 200 ms window. `:erpm` takes the erpm, the controller's speed
      estimate, which without Hall sensors and at low speed can be far
      from the shaft's.
    * `:noise_rpm` — motor rpm at or below which `:direction` reads
      `"stopped"`: a stopped motor reports a stray erpm or two. Default 5.
    * `:max_throttle`, `:max_reverse` — the fraction of the motor's full
      output a hand's full forward and full negative requests give, or
      with a gear source a full request in `:drive` and in `:reverse`.
      The output is the duty, or `:max_current` with `:hand_control`
      `:current`. Fractions in [0, 1], defaulting to 1, `:max_reverse` to
      `:max_throttle`. The
      caps scale rather than clip, and do not apply to a velocity,
      which `:max_rotation_per_minute` already bounds.
    * `:hand_control` — `:duty` (default) or `:current`, see above.
    * `:max_current` — amperes at a full hand request, with
      `:hand_control` `:current`. The VESC's own current limits stay
      in force below it.
    * `:min_current` — amperes at the smallest hand request above zero,
      with `:hand_control` `:current`. Default 0.
    * `:selected_gear_source` — optional, the manager publishing
      `:selected_gear`. Needs `:max_brake_current` and the
      `set_current_brake` frame.
    * `:max_brake_current` — amperes of braking current at a full
      negative request. The VESC's own current limits stay in force
      below it.

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
  alias OvcsBus.Units
  alias Cantastic.{Emitter, Frame, Receiver, ReceivedFrameWatcher, Signal}
  alias VmsCore.NormalisedRequest

  @loop_period 10
  @frame_suffixes [:set_duty, :set_current, :set_current_brake, :set_rpm, :status, :status_5]
  @tachometer_window_ms 200
  @zero D.new(0)
  @one D.new(1)
  @gear_signs %{drive: 1, reverse: -1}
  @command_labels %{
    set_current: "release",
    set_current_brake: "brake",
    set_duty: "duty",
    set_rpm: "speed"
  }

  def child_spec(%{process_name: process_name} = args) do
    %{id: process_name, start: {__MODULE__, :start_link, [args]}}
  end

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

    # Every command emitter exists from the start, none enabled: the
    # first tick enables the one for the selected source. The brake
    # only exists with gears. The emitters outlive this process, so a
    # restart disables them too: otherwise the one a previous run left
    # enabled keeps sending alongside the new one.
    selected_gear_source = Map.get(args, :selected_gear_source)
    :ok = configure_emitter(network, frames.set_duty, %{"duty" => @zero})
    :ok = configure_emitter(network, frames.set_current, %{"current" => @zero})
    :ok = configure_emitter(network, frames.set_rpm, %{"erpm" => 0})

    if selected_gear_source do
      :ok = configure_emitter(network, frames.set_current_brake, %{"current" => @zero})
    end

    :ok = Emitter.disable(network, command_frame_names(frames, selected_gear_source))

    {:ok, timer} = :timer.send_interval(@loop_period, :loop)
    hand_control = hand_control(args)
    max_brake_current = brake_current(selected_gear_source, args)
    broadcast_settings(%{process_name: process_name}, hand_control, max_brake_current)

    {:ok,
     %{
       loop_timer: timer,
       process_name: process_name,
       network: network,
       frames: frames,
       selected_control_level_source: selected_control_level_source,
       linear_sources: Map.get(args, :linear_sources, []),
       caps: caps(args),
       hand_control: hand_control,
       selected_gear_source: selected_gear_source,
       # Unknown until the manager publishes it: a hand releases the
       # motor rather than guess a direction.
       selected_gear: nil,
       max_brake_current: max_brake_current,
       erpm_per_request: erpm_per_request(max_rotation_per_minute, pole_pairs),
       pole_pairs: pole_pairs,
       noise_rpm: D.new(Map.get(args, :noise_rpm, 5)),
       rotation_from: rotation_from(Map.get(args, :rotation_from, :tachometer)),
       tachometer_samples: [],
       # Nothing commands this actuator until the manager names a
       # source.
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
    # Zero on the way to a level that commands nothing: with no source
    # no request message matches, and the last request would be held.
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

  def handle_info(
        %Bus.Message{name: :selected_gear, value: selected_gear, source: source},
        state
      )
      when not is_nil(source) and source == state.selected_gear_source do
    {:noreply, %{state | selected_gear: selected_gear}}
  end

  def handle_info(%Bus.Message{}, state) do
    {:noreply, state}
  end

  # Published as the frame arrives, not on the tick: the values only
  # change with a frame.
  def handle_info({:handle_frame, %Frame{name: name, signals: signals}}, state)
      when name == state.frames.status do
    %{"erpm" => %Signal{value: erpm}, "motor_current" => %Signal{value: motor_current}} = signals

    if state.rotation_from == :erpm,
      do: broadcast_rotation(state, rotation_per_minute(erpm, state.pole_pairs))

    broadcast(state, :motor_current, motor_current, Units.ampere())
    {:noreply, state}
  end

  def handle_info({:handle_frame, %Frame{name: name, signals: signals}}, state)
      when name == state.frames.status_5 do
    %{
      "tachometer" => %Signal{value: tachometer},
      "input_voltage" => %Signal{value: input_voltage}
    } =
      signals

    {rotation, samples} =
      tachometer_rotation(
        state.tachometer_samples,
        {System.monotonic_time(:millisecond), tachometer},
        state.pole_pairs
      )

    if state.rotation_from == :tachometer and not is_nil(rotation),
      do: broadcast_rotation(state, rotation)

    broadcast(state, :revolutions, revolutions(tachometer, state.pole_pairs), Units.revolution())
    broadcast(state, :input_voltage, input_voltage, Units.volt())
    {:noreply, %{state | tachometer_samples: samples}}
  end

  def handle_info({:handle_missing_frame, network, name}, state)
      when network == state.network and name == state.frames.status do
    if state.rotation_from == :erpm, do: broadcast_rotation(state, nil)
    broadcast(state, :motor_current, nil, Units.ampere())
    {:noreply, state}
  end

  def handle_info({:handle_missing_frame, network, name}, state)
      when network == state.network and name == state.frames.status_5 do
    if state.rotation_from == :tachometer, do: broadcast_rotation(state, nil)
    broadcast(state, :revolutions, nil, Units.revolution())
    broadcast(state, :input_voltage, nil, Units.volt())
    {:noreply, %{state | tachometer_samples: []}}
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

        broadcast(state, :throttle, throttle, Units.fraction())
        broadcast(state, :command, label(frame, data), nil)
        broadcast(state, :brake_current, commanded_brake_current(frame, data), Units.ampere())
        broadcast(state, :drive_current, commanded_drive_current(frame, data), Units.ampere())
        %{state | command: command}
    end
  end

  defp label(:set_current, %{"current" => current}),
    do: if(D.eq?(current, @zero), do: "release", else: "current")

  defp label(frame, _data), do: @command_labels[frame]

  defp commanded_brake_current(:set_current_brake, %{"current" => current}), do: current
  defp commanded_brake_current(_frame, _data), do: @zero

  defp commanded_drive_current(:set_current, %{"current" => current}), do: current
  defp commanded_drive_current(_frame, _data), do: @zero

  # Published once: they never change while the process lives.
  defp broadcast_settings(state, hand_control, max_brake_current) do
    {mode, min_current, max_current} =
      case hand_control do
        :duty -> {"duty", nil, nil}
        {:current, min_current, max_current} -> {"current", min_current, max_current}
      end

    broadcast(state, :hand_control, mode, nil)
    broadcast(state, :min_current, min_current, Units.ampere())
    broadcast(state, :max_current, max_current, Units.ampere())
    broadcast(state, :max_brake_current, max_brake_current, Units.ampere())
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
  one of `:set_current`, `:set_current_brake`, `:set_duty` and
  `:set_rpm`, `data` its signals, and `throttle` the normalised command
  in [-1, 1] the dashboard shows — the duty or the fraction of
  `:max_current` for a hand, the fraction of the maximum rpm for a
  velocity, zero for none and for a brake. Its
  sign is the direction the motor is driven in, never the brake's.
  """
  def command(%{requested_throttle_source: nil}), do: release()

  def command(state) do
    cond do
      state.requested_throttle_source in state.linear_sources -> velocity_command(state)
      is_nil(state[:selected_gear_source]) -> signed_duty_command(state)
      true -> geared_command(state)
    end
  end

  defp velocity_command(state) do
    requested = NormalisedRequest.clamp(state.requested_throttle)

    if D.eq?(requested, @zero) do
      {:set_duty, %{"duty" => @zero}, @zero}
    else
      {:set_rpm, %{"erpm" => erpm_setpoint(requested, state.erpm_per_request)}, requested}
    end
  end

  defp signed_duty_command(state) do
    requested = NormalisedRequest.clamp(state.requested_throttle)

    duty =
      requested
      |> D.abs()
      |> D.mult(cap(requested, state.caps))
      |> NormalisedRequest.signed_as(requested)

    hand_output(duty, state)
  end

  defp geared_command(state) do
    requested = NormalisedRequest.clamp(state.requested_throttle)
    gear_sign = Map.get(@gear_signs, state.selected_gear)

    cond do
      D.negative?(requested) ->
        brake_command(requested, state)

      is_nil(gear_sign) ->
        release()

      D.eq?(requested, @zero) ->
        release()

      true ->
        # A request of the gear's sign, so reverse gets the reverse cap.
        signed = D.mult(requested, gear_sign)

        duty =
          signed
          |> D.abs()
          |> D.mult(cap(signed, state.caps))
          |> NormalisedRequest.signed_as(signed)

        hand_output(duty, state)
    end
  end

  # `output` is the capped, signed fraction of the motor's full output.
  defp hand_output(output, %{hand_control: {:current, min_current, max_current}}) do
    if D.eq?(output, @zero) do
      release()
    else
      current =
        output
        |> D.abs()
        |> D.mult(D.sub(max_current, min_current))
        |> D.add(min_current)
        |> NormalisedRequest.signed_as(output)
        |> D.round(3)

      {:set_current, %{"current" => current}, output}
    end
  end

  defp hand_output(output, _state), do: {:set_duty, %{"duty" => output}, output}

  defp brake_command(requested, state) do
    current = requested |> D.abs() |> D.mult(state.max_brake_current) |> D.round(3)
    {:set_current_brake, %{"current" => current}, @zero}
  end

  defp cap(requested, caps) do
    if D.negative?(requested), do: caps.max_reverse, else: caps.max_throttle
  end

  @doc false
  def caps(args) do
    max_throttle = Map.get(args, :max_throttle, @one)
    caps = %{max_throttle: max_throttle, max_reverse: Map.get(args, :max_reverse, max_throttle)}

    Enum.each(caps, fn {key, value} ->
      if D.negative?(value) or D.gt?(value, @one) do
        raise ArgumentError, "#{inspect(key)} must be in [0, 1], got #{value}"
      end
    end)

    caps
  end

  @doc false
  def hand_control(args) do
    min_current = Map.get(args, :min_current, 0)

    case {Map.get(args, :hand_control, :duty), Map.get(args, :max_current)} do
      {:duty, _} ->
        :duty

      {:current, max_current}
      when is_number(max_current) and is_number(min_current) and
             0 <= min_current and min_current < max_current ->
        {:current, D.from_float(1.0 * min_current), D.from_float(1.0 * max_current)}

      {:current, _} ->
        raise ArgumentError,
              ":hand_control :current needs :max_current above :min_current (0 or more)"

      {other, _} ->
        raise ArgumentError, ":hand_control must be :duty or :current, got #{inspect(other)}"
    end
  end

  defp release, do: {:set_current, %{"current" => @zero}, @zero}

  defp brake_current(nil, _args), do: nil

  defp brake_current(_selected_gear_source, %{max_brake_current: max_brake_current}),
    do: D.from_float(1.0 * max_brake_current)

  defp brake_current(_selected_gear_source, _args),
    do: raise(ArgumentError, ":selected_gear_source needs :max_brake_current")

  @doc false
  def erpm_setpoint(requested, erpm_per_request) do
    requested |> D.mult(erpm_per_request) |> D.round() |> D.to_integer()
  end

  # Electrical rpm at a request of 1.
  @doc false
  def erpm_per_request(max_rotation_per_minute, pole_pairs) do
    D.from_float(1.0 * max_rotation_per_minute * pole_pairs)
  end

  @doc """
  Which way the motor turns: `"forward"` or `"backward"` above
  `noise_rpm`, `"stopped"` within it.
  """
  def direction(rotation, noise_rpm) do
    cond do
      D.gt?(rotation, noise_rpm) -> "forward"
      D.lt?(rotation, D.negate(noise_rpm)) -> "backward"
      true -> "stopped"
    end
  end

  defp broadcast_rotation(state, rotation) do
    broadcast(state, :rotation_per_minute, rotation, Units.revolution_per_minute())
    broadcast(state, :direction, rotation && direction(rotation, state.noise_rpm), nil)
  end

  defp rotation_from(source) when source in [:tachometer, :erpm], do: source

  defp rotation_from(source) do
    raise ArgumentError, ":rotation_from must be :tachometer or :erpm, got #{inspect(source)}"
  end

  # The mechanical rpm of the motor, signed like the erpm it comes from.
  @doc false
  def rotation_per_minute(erpm, pole_pairs) do
    erpm |> D.new() |> D.div(pole_pairs) |> D.round(1)
  end

  # The tachometer counts 6 steps per electrical turn.
  @doc false
  def revolutions(tachometer, pole_pairs) do
    tachometer |> D.new() |> D.div(6 * pole_pairs)
  end

  # The mechanical rpm over the samples of the last window, newest
  # first, and the samples to keep. Nil until the window spans two
  # samples: one count says nothing about a rate.
  @doc false
  def tachometer_rotation(samples, {now_ms, _count} = sample, pole_pairs) do
    samples = [
      sample | Enum.take_while(samples, fn {at, _} -> now_ms - at <= @tachometer_window_ms end)
    ]

    case List.last(samples) do
      {^now_ms, _} ->
        {nil, samples}

      {oldest_ms, oldest_count} ->
        {_, count} = sample

        rotation =
          D.new(count - oldest_count)
          |> D.mult(60_000)
          |> D.div(6 * pole_pairs * (now_ms - oldest_ms))
          |> D.round(1)

        {rotation, samples}
    end
  end

  @doc false
  def frame_names(process_name) do
    prefix = Macro.underscore(process_name) |> String.split("/") |> List.last()
    Map.new(@frame_suffixes, fn suffix -> {suffix, "#{prefix}_#{suffix}"} end)
  end

  defp broadcast(state, name, value, unit) do
    Bus.broadcast("messages", %Bus.Message{
      name: name,
      value: value,
      unit: unit,
      source: state.process_name
    })
  end

  defp command_frame_names(frames, nil), do: [frames.set_duty, frames.set_current, frames.set_rpm]

  defp command_frame_names(frames, _selected_gear_source),
    do: [frames.set_duty, frames.set_current, frames.set_rpm, frames.set_current_brake]

  defp configure_emitter(network, frame_name, initial_data) do
    Emitter.configure(network, frame_name, %{
      parameters_builder_function: :default,
      initial_data: initial_data,
      enable: false
    })
  end
end
