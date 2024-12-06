defmodule VmsCore.Components.OVCS.GenericController do
  @moduledoc """
    Generic controller based on an Arduino R4 Minima
  """
  use GenServer

  alias Cantastic.{Emitter, Frame, Signal, Receiver, ReceivedFrameWatcher}
  alias VmsCore.{Application, Bus}
  @pwm_duty_cycle_range 65_535
  alias Decimal, as: D
  @loop_period 50

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
    "digital_pin18_enabled" => false,
  }

  @pwm_pins %{
    "pwm_pin0_duty_cycle" => 0,
    "pwm_pin1_duty_cycle" => 0,
    "pwm_pin2_duty_cycle" => 0,
  }

  @dac_pins %{
    "dac_pin0_duty_cycle" => 0
  }

  @analog_pins %{
    "analog_pin0_value" => 0,
    "analog_pin1_value" => 0,
    "analog_pin2_value" => 0
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
    "external_pwm3_frequency" => 0,
  }

  def start_link(%{process_name: process_name} = args) do
    GenServer.start_link(__MODULE__, args, name: process_name)
  end

  @impl true
  def init(%{process_name:  process_name, control_digital_pins: control_digital_pins, control_other_pins: control_other_pins, enabled_external_pwms: enabled_external_pwms}) do
    alive_frame_name                         = compute_frame_name(process_name, "alive")
    digital_and_analog_pin_status_frame_name = compute_frame_name(process_name, "digital_and_analog_pin_status")
    digital_pin_request_frame_name           = compute_frame_name(process_name, "digital_pin_request")
    other_pin_request_frame_name             = compute_frame_name(process_name, "other_pin_request")
    external_pwm_request_frame_names         = [
      compute_frame_name(process_name, "external_pwm0_request"),
      compute_frame_name(process_name, "external_pwm1_request"),
      compute_frame_name(process_name, "external_pwm2_request"),
      compute_frame_name(process_name, "external_pwm3_request")
    ]
    :ok = Receiver.subscribe(self(), :ovcs, [alive_frame_name, digital_and_analog_pin_status_frame_name])
    :ok = ReceivedFrameWatcher.enable(:ovcs, alive_frame_name)

    if control_digital_pins do
      :ok = Emitter.configure(:ovcs, digital_pin_request_frame_name, %{
        parameters_builder_function: :default,
        initial_data: @digital_pins,
        enable: true
      })
    end

    if control_other_pins do
      :ok = Emitter.configure(:ovcs, other_pin_request_frame_name, %{
        parameters_builder_function: :default,
        initial_data: @pwm_pins |> Map.merge(@dac_pins),
        enable: true
      })
    end
    enabled_external_pwms |> Enum.each(fn(pwm_id) ->
      :ok = Emitter.configure(:ovcs, external_pwm_request_frame_names |> Enum.at(pwm_id), %{
        parameters_builder_function: :default,
        initial_data: %{
          "enabled" => @external_pwm_pins["external_pwm#{pwm_id}_enabled"],
          "duty_cycle" => @external_pwm_pins["external_pwm#{pwm_id}_duty_cycle"],
          "frequency" => @external_pwm_pins["external_pwm#{pwm_id}_frequency"],
        },
        enable: true
      })
    end)
    enabled_pin_names = Application.vehicle_compposer().generic_controllers()[process_name] |> Enum.flat_map(fn({key, value}) ->
      case value != "disabled" do
        true -> case key do
         "digital_pin" <> _ -> [key <> "_enabled"]
         "analog_pin" <> _ -> [key <> "_value"]
         "pwm_pin" <> _ -> [key <> "_duty_cycle"]
         "dac_pin" <> _ -> [key <> "_duty_cycle"]
         _ -> []
        end
        false -> []
      end
    end)
    enabled_pin_names = enabled_pin_names ++ (enabled_external_pwms |> Enum.flat_map(fn(external_pwm_id) ->
      ["external_pwm#{external_pwm_id}_enabled", "external_pwm#{external_pwm_id}_duty_cycle", "external_pwm#{external_pwm_id}_frequency"]
    end))
    requested_pin_names = enabled_pin_names |> Enum.filter(fn(name) ->
      case name do
        "digital" <> _ -> true
        "pwm" <> _ -> true
        "dac" <> _ -> true
        "external_pwm" <> _ -> true
        _ -> false
      end
    end)
    received_pin_names = enabled_pin_names |> Enum.filter(fn(name) ->
      case name do
        "digital" <> _ -> true
        "analog" <> _ -> true
        _ -> false
      end
    end)
    {:ok, timer} = :timer.send_interval(@loop_period, :loop)
    {:ok, %{
      loop_timer: timer,
      process_name: process_name,
      alive_frame_name: alive_frame_name,
      digital_and_analog_pin_status_frame_name: digital_and_analog_pin_status_frame_name,
      digital_pin_request_frame_name: digital_pin_request_frame_name,
      other_pin_request_frame_name: other_pin_request_frame_name,
      external_pwm_request_frame_names: external_pwm_request_frame_names,
      received_pins: @digital_pins |> Map.merge(@analog_pins),
      requested_pins:  @digital_pins |> Map.merge(@pwm_pins) |> Map.merge(@dac_pins) |> Map.merge(@external_pwm_pins),
      enabled_external_pwms: enabled_external_pwms,
      control_digital_pins: control_digital_pins,
      control_other_pins: control_other_pins,
      requested_pin_names: requested_pin_names,
      received_pin_names: received_pin_names,
      status: nil,
      expansion_board1_last_error: nil,
      expansion_board2_last_error: nil
    }}
  end

  @impl true
  def handle_info(:loop, state) do
    state = state
      |> emit_metrics()
    {:noreply, state}
  end

  @impl true
  def handle_info({:handle_frame,  %Frame{name: name, signals: signals}}, state) when name == state.digital_and_analog_pin_status_frame_name do
    received_pins = signals |> Enum.reduce(%{}, fn ({_, signal}, pins) ->
      Map.put(pins, signal.name, signal.value)
    end)
    {:noreply, %{state | received_pins: received_pins}}
  end

  @impl true
  def handle_info({:handle_frame,  %Frame{name: name, signals: signals} = _frame}, state) when name == state.alive_frame_name do
    %{
      "status"                      => %Signal{value: status},
      "expansion_board1_last_error" => %Signal{value: expansion_board1_last_error},
      "expansion_board2_last_error" => %Signal{value: expansion_board2_last_error}
    } = signals

    {:noreply, %{state |
      status: status,
      expansion_board1_last_error: expansion_board1_last_error,
      expansion_board2_last_error: expansion_board2_last_error
    }}
  end

  @impl true
  def handle_call({:set_digital_value, pin, value},  _from, state) do
    pin_name = "digital_pin#{pin}_enabled"
    :ok = Emitter.update(:ovcs, state.digital_pin_request_frame_name, fn (data) ->
      %{data | pin_name => value}
    end)
    requested_pins = %{state.requested_pins | pin_name => value}
    {:reply, :ok, %{state | requested_pins: requested_pins}}
  end

  @impl true
  def handle_call({:set_pwm_duty_cycle, pin, duty_cycle},  _from, state) do
    pin_name = "pwm_pin#{pin}_duty_cycle"
    :ok = Emitter.update(:ovcs, state.pwm_pin_request_frame_name, fn (data) ->
      %{data | "pwm_pin#{pin}_duty_cycle" => duty_cycle}
    end)
    requested_pins = %{state.requested_pins | pin_name => duty_cycle}
    {:reply, :ok, %{state | requested_pins: requested_pins}}
  end

  @impl true
  def handle_call({:set_external_pwm, pwm_id, enabled, duty_cycle_percentage, frequency},  _from, state) do
    duty_cycle = duty_cycle_percentage |> D.mult(@pwm_duty_cycle_range)
    :ok = Emitter.update(:ovcs, state.external_pwm_request_frame_names |> Enum.at(pwm_id), fn (data) ->
      %{data |
      "enabled" => enabled,
      "duty_cycle" => duty_cycle,
      "frequency" => frequency
    }
    end)
    pin_name = "external_pwm#{pwm_id}"
    requested_pins = %{state.requested_pins |
      "#{pin_name}_enabled" => enabled,
      "#{pin_name}_duty_cycle" => duty_cycle_percentage,
      "#{pin_name}_frequency" => frequency
    }
    {:reply, :ok, %{state | requested_pins: requested_pins}}
  end

  @impl true
  def handle_call({:set_dac_duty_cycle, duty_cycle},  _from, state) do
    pin_name = "dac_pin0_duty_cycle"
    :ok = Emitter.update(:ovcs, state.other_pin_request_frame_name, fn (data) ->
      %{data | pin_name => duty_cycle}
    end)
    requested_pins = %{state.requested_pins | pin_name => duty_cycle}
    {:reply, :ok, %{state | requested_pins: requested_pins}}
  end

  @impl true
  def handle_call({:get_digital_value, pin},  _from, state) do
    value = state.received_pins["digital_pin#{pin}_enabled"]
    {:reply, {:ok, value}, state}
  end

  @impl true
  def handle_call({:get_analog_value, pin},  _from, state) do
    value = state.received_pins["analog_pin#{pin}_value"]
    {:reply, {:ok, value}, state}
  end

  def set_digital_value(controller, pin, value) do
    GenServer.call(controller, {:set_digital_value, pin, value})
  end

  def set_pwm_duty_cycle(controller, pin, duty_cycle) do
    GenServer.call(controller, {:set_pwm_duty_cycle, pin, duty_cycle})
  end

  def set_dac_duty_cycle(controller, duty_cycle) do
    GenServer.call(controller, {:set_dac_value, duty_cycle})
  end

  def set_external_pwm(controller, pwm_id, enabled, duty_cycle_percentage, frequency) do
    GenServer.call(controller, {:set_external_pwm, pwm_id, enabled, duty_cycle_percentage, frequency})
  end

  def get_analog_value(controller, pin) do
    GenServer.call(controller, {:get_analog_value, pin})
  end

  def get_digital_value(controller, pin) do
    GenServer.call(controller, {:get_digital_value, pin})
  end

  def trigger_action("adopt", params) do
    controller_name = params["controller_name"] |> String.to_existing_atom
    start_adoption(controller_name)
    :timer.sleep(1000)
    stop_adoption()
  end

  def start_adoption(controller_name) do
    :ok = Emitter.configure(:ovcs, "controller_configuration", %{
      parameters_builder_function: :default,
      initial_data: Application.vehicle_compposer().generic_controllers()[controller_name],
      enable: true
    })
  end

  def stop_adoption do
    Emitter.disable(:ovcs, "controller_configuration")
  end

  defp compute_frame_name(process_name, suffix) do
    controller_name = Macro.underscore(process_name) |> String.split("/") |> List.last()
    "#{controller_name}_#{suffix}"
  end

  defp emit_metrics(state) do
    state.received_pin_names |> Enum.each(fn(name) ->
      value = state.received_pins[name]
      Bus.broadcast("messages", %Bus.Message{name: "received_#{name}" |> String.to_atom(), value: value, source: state.process_name})
    end)
    state.requested_pin_names |> Enum.each(fn(name) ->
      value = state.requested_pins[name]
      Bus.broadcast("messages", %Bus.Message{name: "requested_#{name}" |> String.to_atom(), value: value, source: state.process_name})
    end)
    {:ok, is_alive} = ReceivedFrameWatcher.is_alive?(:ovcs, state.alive_frame_name)
    Bus.broadcast("messages", %Bus.Message{name: :is_alive, value: is_alive, source: state.process_name})
    Bus.broadcast("messages", %Bus.Message{name: :status, value: state.status, source: state.process_name})
    Bus.broadcast("messages", %Bus.Message{name: :expansion_board1_last_error, value: state.expansion_board1_last_error, source: state.process_name})
    Bus.broadcast("messages", %Bus.Message{name: :expansion_board2_last_error, value: state.expansion_board2_last_error, source: state.process_name})
    state
  end
end
