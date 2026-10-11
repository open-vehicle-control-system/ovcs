defmodule VmsCore.Components.OVCS.GenericController do
  @moduledoc """
  Driver for one OVCS generic controller, an Arduino R4 Minima on the
  `:ovcs` network.

  Its pins are configured by the vehicle composer's
  `generic_controllers/0`, under the controller's process name. This
  process emits the pin requests other components make through
  `set_digital_value/3`, `set_pwm_duty_cycle/3`, `set_dac_duty_cycle/2`
  and `set_external_pwm/5`, keeps the pin statuses the controller
  reports, and broadcasts every enabled pin as `:received_<pin>` and
  `:requested_<pin>`, along with `:is_alive`, `:status` and the
  expansion boards' last errors.

  ## Options

    * `:process_name` — the name this process registers under, the
      source of its messages and the prefix of its frame names.
    * `:control_digital_pins` — emit the digital pin request frame.
    * `:control_other_pins` — emit the PWM and DAC pin request frame.
    * `:enabled_external_pwms` — ids of the external PWMs to drive.
  """
  use GenServer

  alias Decimal, as: D
  alias Cantastic.{Emitter, Frame, Receiver, ReceivedFrameWatcher, Signal}
  alias OvcsBus, as: Bus
  alias OvcsBus.Units
  alias VmsCore.Application

  # Full scale of the 16-bit external PWM duty_cycle signal.
  @pwm_duty_cycle_range 65_535
  @loop_period_ms 50
  @adoption_duration_ms 1000

  @digital_pins %{
    "digital_pin0_enabled" => false,
    "digital_pin1_enabled" => false,
    "digital_pin2_enabled" => false,
    "digital_pin3_enabled" => false,
    "digital_pin4_enabled" => false,
    "digital_pin5_enabled" => false,
    "digital_pin6_enabled" => false,
    "digital_pin7_enabled" => false,
    "digital_pin8_enabled" => false,
    "digital_pin9_enabled" => false,
    "digital_pin10_enabled" => false,
    "digital_pin11_enabled" => false,
    "digital_pin12_enabled" => false,
    "digital_pin13_enabled" => false,
    "digital_pin14_enabled" => false,
    "digital_pin15_enabled" => false,
    "digital_pin16_enabled" => false,
    "digital_pin17_enabled" => false,
    "digital_pin18_enabled" => false
  }

  @pwm_pins %{
    "pwm_pin0_duty_cycle" => 0,
    "pwm_pin1_duty_cycle" => 0,
    "pwm_pin2_duty_cycle" => 0
  }

  @dac_pins %{
    "dac_pin0_duty_cycle" => 0
  }

  @analog_pins %{
    "analog_pin0_value" => 0,
    "analog_pin1_value" => 0,
    "analog_pin2_value" => 0
  }

  # Reported on a frame of their own, and only by a controller whose
  # pulse pin is enabled: the other controllers declare no such frame.
  @pulse_pins %{
    "pulse_pin0_count" => 0,
    "pulse_pin0_frequency" => 0
  }

  @external_pwm_pins %{
    "external_pwm0_enabled" => false,
    "external_pwm0_duty_cycle" => 0,
    "external_pwm0_frequency" => 0,
    "external_pwm1_enabled" => false,
    "external_pwm1_duty_cycle" => 0,
    "external_pwm1_frequency" => 0,
    "external_pwm2_enabled" => false,
    "external_pwm2_duty_cycle" => 0,
    "external_pwm2_frequency" => 0,
    "external_pwm3_enabled" => false,
    "external_pwm3_duty_cycle" => 0,
    "external_pwm3_frequency" => 0
  }

  def start_link(%{process_name: process_name} = args) do
    GenServer.start_link(__MODULE__, args, name: process_name)
  end

  @impl GenServer
  def init(%{
        process_name: process_name,
        control_digital_pins: control_digital_pins,
        control_other_pins: control_other_pins,
        enabled_external_pwms: enabled_external_pwms
      }) do
    alive_frame_name = compute_frame_name(process_name, "alive")

    digital_and_analog_pin_status_frame_name =
      compute_frame_name(process_name, "digital_and_analog_pin_status")

    pulse_counter_status_frame_name = compute_frame_name(process_name, "pulse_counter_status")
    digital_pin_request_frame_name = compute_frame_name(process_name, "digital_pin_request")
    other_pin_request_frame_name = compute_frame_name(process_name, "other_pin_request")

    external_pwm_request_frame_names = [
      compute_frame_name(process_name, "external_pwm0_request"),
      compute_frame_name(process_name, "external_pwm1_request"),
      compute_frame_name(process_name, "external_pwm2_request"),
      compute_frame_name(process_name, "external_pwm3_request")
    ]

    controller_configuration = Application.vehicle_composer().generic_controllers()[process_name]
    pulse_pin_enabled = controller_configuration["pulse_pin0"] == "enabled"

    # Both live on A1. The firmware gives the pin to the pulse counter
    # and reports the analog input as a permanent zero, which would
    # look like a real reading; refuse the combination here instead.
    if pulse_pin_enabled and controller_configuration["analog_pin0"] == "enabled" do
      raise ArgumentError,
            "#{inspect(process_name)} enables both pulse_pin0 and analog_pin0, which share A1"
    end

    :ok =
      Receiver.subscribe(self(), :ovcs, [
        alive_frame_name,
        digital_and_analog_pin_status_frame_name
      ])

    # Watched as well as subscribed: a controller whose firmware lacks this
    # frame never emits it, and a stale frequency would read as standstill.
    # While the frame is dead the pulse signals are broadcast as nil.
    if pulse_pin_enabled do
      :ok = Receiver.subscribe(self(), :ovcs, pulse_counter_status_frame_name)
      :ok = ReceivedFrameWatcher.enable(:ovcs, pulse_counter_status_frame_name)
    end

    :ok = ReceivedFrameWatcher.enable(:ovcs, alive_frame_name)

    if control_digital_pins do
      :ok =
        Emitter.configure(:ovcs, digital_pin_request_frame_name, %{
          parameters_builder_function: :default,
          initial_data: @digital_pins,
          enable: true
        })
    end

    if control_other_pins do
      :ok =
        Emitter.configure(:ovcs, other_pin_request_frame_name, %{
          parameters_builder_function: :default,
          initial_data: @pwm_pins |> Map.merge(@dac_pins),
          enable: true
        })
    end

    enabled_external_pwms
    |> Enum.each(fn pwm_id ->
      :ok =
        Emitter.configure(:ovcs, external_pwm_request_frame_names |> Enum.at(pwm_id), %{
          parameters_builder_function: :default,
          initial_data: %{
            "enabled" => @external_pwm_pins["external_pwm#{pwm_id}_enabled"],
            "duty_cycle" => @external_pwm_pins["external_pwm#{pwm_id}_duty_cycle"],
            "frequency" => @external_pwm_pins["external_pwm#{pwm_id}_frequency"]
          },
          enable: true
        })
    end)

    enabled_pin_names =
      controller_configuration
      |> Enum.flat_map(fn {pin, pin_mode} ->
        case pin_mode != "disabled" do
          true ->
            case pin do
              "digital_pin" <> _ -> [pin <> "_enabled"]
              "analog_pin" <> _ -> [pin <> "_value"]
              "pulse_pin" <> _ -> [pin <> "_count", pin <> "_frequency"]
              "pwm_pin" <> _ -> [pin <> "_duty_cycle"]
              "dac_pin" <> _ -> [pin <> "_duty_cycle"]
              _ -> []
            end

          false ->
            []
        end
      end)

    enabled_pin_names =
      enabled_pin_names ++
        (enabled_external_pwms
         |> Enum.flat_map(fn external_pwm_id ->
           [
             "external_pwm#{external_pwm_id}_enabled",
             "external_pwm#{external_pwm_id}_duty_cycle",
             "external_pwm#{external_pwm_id}_frequency"
           ]
         end))

    requested_pin_names =
      enabled_pin_names
      |> Enum.filter(fn name ->
        case name do
          "digital" <> _ -> true
          "pwm" <> _ -> true
          "dac" <> _ -> true
          "external_pwm" <> _ -> true
          _ -> false
        end
      end)

    received_pin_names =
      enabled_pin_names
      |> Enum.filter(fn name ->
        case name do
          "digital" <> _ -> true
          "analog" <> _ -> true
          "pulse" <> _ -> true
          _ -> false
        end
      end)

    {:ok, timer} = :timer.send_interval(@loop_period_ms, :loop)

    {:ok,
     %{
       loop_timer: timer,
       process_name: process_name,
       alive_frame_name: alive_frame_name,
       digital_and_analog_pin_status_frame_name: digital_and_analog_pin_status_frame_name,
       pulse_counter_status_frame_name: pulse_counter_status_frame_name,
       digital_pin_request_frame_name: digital_pin_request_frame_name,
       other_pin_request_frame_name: other_pin_request_frame_name,
       external_pwm_request_frame_names: external_pwm_request_frame_names,
       received_pins: @digital_pins |> Map.merge(@analog_pins) |> Map.merge(@pulse_pins),
       requested_pins:
         @digital_pins
         |> Map.merge(@pwm_pins)
         |> Map.merge(@dac_pins)
         |> Map.merge(@external_pwm_pins),
       enabled_external_pwms: enabled_external_pwms,
       control_digital_pins: control_digital_pins,
       control_other_pins: control_other_pins,
       requested_pin_names: requested_pin_names,
       received_pin_names: received_pin_names,
       pulse_pin_enabled: pulse_pin_enabled,
       status: nil,
       expansion_board1_last_error: nil,
       expansion_board2_last_error: nil
     }}
  end

  @impl GenServer
  def handle_info(:loop, state) do
    state =
      state
      |> emit_metrics()

    {:noreply, state}
  end

  # Two frames feed `received_pins`, so each merges its own signals
  # rather than replacing the map, or the other frame's values would be
  # wiped on its next arrival.
  def handle_info({:handle_frame, %Frame{name: name, signals: signals}}, state)
      when name == state.digital_and_analog_pin_status_frame_name do
    {:noreply, %{state | received_pins: merge_signals(state.received_pins, signals)}}
  end

  # Broadcast per frame, so an integrator can tell a fresh sample from a held
  # one, and only while the frame is alive: otherwise the tick declares them
  # unknown and the two would alternate.
  def handle_info({:handle_frame, %Frame{name: name, signals: signals}}, state)
      when name == state.pulse_counter_status_frame_name do
    received_pins = merge_signals(state.received_pins, signals)
    state = %{state | received_pins: received_pins}

    if pulse_frame_alive?(state) do
      Enum.each(signals, fn {_, signal} ->
        broadcast_received_pin(state, signal.name, signal.value)
      end)
    end

    {:noreply, state}
  end

  def handle_info({:handle_frame, %Frame{name: name, signals: signals}}, state)
      when name == state.alive_frame_name do
    %{
      "status" => %Signal{value: status},
      "expansion_board1_last_error" => %Signal{value: expansion_board1_last_error},
      "expansion_board2_last_error" => %Signal{value: expansion_board2_last_error}
    } = signals

    {:noreply,
     %{
       state
       | status: status,
         expansion_board1_last_error: expansion_board1_last_error,
         expansion_board2_last_error: expansion_board2_last_error
     }}
  end

  @impl GenServer
  def handle_call({:set_digital_value, pin, enabled}, _from, state) do
    pin_name = "digital_pin#{pin}_enabled"

    :ok =
      Emitter.update(:ovcs, state.digital_pin_request_frame_name, fn frame_data ->
        %{frame_data | pin_name => enabled}
      end)

    requested_pins = %{state.requested_pins | pin_name => enabled}
    {:reply, :ok, %{state | requested_pins: requested_pins}}
  end

  def handle_call({:set_pwm_duty_cycle, pin, duty_cycle}, _from, state) do
    pin_name = "pwm_pin#{pin}_duty_cycle"

    :ok =
      Emitter.update(:ovcs, state.other_pin_request_frame_name, fn frame_data ->
        %{frame_data | pin_name => duty_cycle}
      end)

    requested_pins = %{state.requested_pins | pin_name => duty_cycle}
    {:reply, :ok, %{state | requested_pins: requested_pins}}
  end

  def handle_call(
        {:set_external_pwm, pwm_id, enabled, duty_cycle_percentage, frequency},
        _from,
        state
      ) do
    duty_cycle = duty_cycle_percentage |> D.mult(@pwm_duty_cycle_range)

    :ok =
      Emitter.update(
        :ovcs,
        state.external_pwm_request_frame_names |> Enum.at(pwm_id),
        fn frame_data ->
          %{
            frame_data
            | "enabled" => enabled,
              "duty_cycle" => duty_cycle,
              "frequency" => frequency
          }
        end
      )

    pin_name = "external_pwm#{pwm_id}"

    requested_pins = %{
      state.requested_pins
      | "#{pin_name}_enabled" => enabled,
        "#{pin_name}_duty_cycle" => duty_cycle_percentage,
        "#{pin_name}_frequency" => frequency
    }

    {:reply, :ok, %{state | requested_pins: requested_pins}}
  end

  def handle_call({:set_dac_duty_cycle, duty_cycle}, _from, state) do
    pin_name = "dac_pin0_duty_cycle"

    :ok =
      Emitter.update(:ovcs, state.other_pin_request_frame_name, fn frame_data ->
        %{frame_data | pin_name => duty_cycle}
      end)

    requested_pins = %{state.requested_pins | pin_name => duty_cycle}
    {:reply, :ok, %{state | requested_pins: requested_pins}}
  end

  def handle_call({:get_digital_value, pin}, _from, state) do
    enabled = state.received_pins["digital_pin#{pin}_enabled"]
    {:reply, {:ok, enabled}, state}
  end

  def handle_call({:get_analog_value, pin}, _from, state) do
    reading = state.received_pins["analog_pin#{pin}_value"]
    {:reply, {:ok, reading}, state}
  end

  @doc "Requests digital output `pin` of `controller` on (`true`) or off."
  def set_digital_value(controller, pin, enabled) do
    GenServer.call(controller, {:set_digital_value, pin, enabled})
  end

  @doc "Requests a raw duty cycle on PWM `pin` of `controller`."
  def set_pwm_duty_cycle(controller, pin, duty_cycle) do
    GenServer.call(controller, {:set_pwm_duty_cycle, pin, duty_cycle})
  end

  @doc "Requests a raw duty cycle on the DAC pin of `controller`."
  def set_dac_duty_cycle(controller, duty_cycle) do
    GenServer.call(controller, {:set_dac_duty_cycle, duty_cycle})
  end

  @doc """
  Requests external PWM `pwm_id` of `controller`: `duty_cycle_percentage`
  is a fraction in [0, 1], `frequency` in hertz.
  """
  def set_external_pwm(controller, pwm_id, enabled, duty_cycle_percentage, frequency) do
    GenServer.call(
      controller,
      {:set_external_pwm, pwm_id, enabled, duty_cycle_percentage, frequency}
    )
  end

  @doc "The last reading of analog `pin` of `controller`, as `{:ok, reading}`."
  def get_analog_value(controller, pin) do
    GenServer.call(controller, {:get_analog_value, pin})
  end

  @doc "The last reported state of digital `pin` of `controller`, as `{:ok, enabled}`."
  def get_digital_value(controller, pin) do
    GenServer.call(controller, {:get_digital_value, pin})
  end

  @doc """
  Dashboard action `"adopt"`: sends the configuration of the controller
  named by `"controller_name"` for `#{@adoption_duration_ms}` ms.
  """
  def trigger_action("adopt", parameters) do
    controller_name = parameters["controller_name"] |> String.to_existing_atom()
    start_adoption(controller_name)
    :timer.sleep(@adoption_duration_ms)
    stop_adoption()
  end

  @doc "Starts emitting `controller_name`'s configuration on the adoption frame."
  def start_adoption(controller_name) do
    :ok =
      Emitter.configure(:ovcs, "controller_configuration", %{
        parameters_builder_function: :default,
        initial_data: Application.vehicle_composer().generic_controllers()[controller_name],
        enable: true
      })
  end

  @doc "Stops emitting the adoption frame."
  def stop_adoption do
    Emitter.disable(:ovcs, "controller_configuration")
  end

  defp pulse_frame_alive?(%{pulse_pin_enabled: false}), do: false

  defp pulse_frame_alive?(state) do
    {:ok, alive} = ReceivedFrameWatcher.is_alive?(:ovcs, state.pulse_counter_status_frame_name)
    alive
  end

  defp compute_frame_name(process_name, suffix) do
    controller_name = Macro.underscore(process_name) |> String.split("/") |> List.last()
    "#{controller_name}_#{suffix}"
  end

  defp merge_signals(received_pins, signals) do
    Enum.reduce(signals, received_pins, fn {_, signal}, pins ->
      Map.put(pins, signal.name, signal.value)
    end)
  end

  defp broadcast_received_pin(state, pin_name, pin_value) do
    Bus.broadcast("messages", %Bus.Message{
      name: "received_#{pin_name}" |> String.to_atom(),
      value: pin_value,
      unit: pin_unit(pin_name),
      source: state.process_name
    })
  end

  defp pin_unit(pin_name) do
    if String.ends_with?(pin_name, "_frequency"), do: Units.hertz()
  end

  # Pulse pins go out per frame; the tick only declares them nil while their frame is dead.
  defp emit_metrics(state) do
    pulse_frame_alive = pulse_frame_alive?(state)

    state.received_pin_names
    |> Enum.each(fn pin_name ->
      case pin_name do
        "pulse" <> _ when not pulse_frame_alive -> broadcast_received_pin(state, pin_name, nil)
        "pulse" <> _ -> :ok
        _ -> broadcast_received_pin(state, pin_name, state.received_pins[pin_name])
      end
    end)

    state.requested_pin_names
    |> Enum.each(fn pin_name ->
      Bus.broadcast("messages", %Bus.Message{
        name: "requested_#{pin_name}" |> String.to_atom(),
        value: state.requested_pins[pin_name],
        unit: pin_unit(pin_name),
        source: state.process_name
      })
    end)

    {:ok, is_alive} = ReceivedFrameWatcher.is_alive?(:ovcs, state.alive_frame_name)

    Bus.broadcast("messages", %Bus.Message{
      name: :is_alive,
      value: is_alive,
      source: state.process_name
    })

    Bus.broadcast("messages", %Bus.Message{
      name: :status,
      value: state.status,
      source: state.process_name
    })

    Bus.broadcast("messages", %Bus.Message{
      name: :expansion_board1_last_error,
      value: state.expansion_board1_last_error,
      source: state.process_name
    })

    Bus.broadcast("messages", %Bus.Message{
      name: :expansion_board2_last_error,
      value: state.expansion_board2_last_error,
      source: state.process_name
    })

    state
  end
end
