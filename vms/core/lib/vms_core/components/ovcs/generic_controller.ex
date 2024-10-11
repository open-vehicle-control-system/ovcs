defmodule VmsCore.Components.OVCS.GenericController do
  use GenServer

  alias Cantastic.{Frame, Emitter, Receiver}
  alias VmsCore.Application

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
    "digital_pin19_enabled" => false,
    "digital_pin20_enabled" => false
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


  def start_link(%{process_name: process_name} = args) do
    GenServer.start_link(__MODULE__, args, name: process_name)
  end

  @impl true
  def init(%{process_name:  process_name, control_digital_pins: control_digital_pins, control_other_pins: control_other_pins}) do
    alive_frame_name                         = compute_frame_name(process_name, "alive")
    digital_and_analog_pin_status_frame_name = compute_frame_name(process_name, "digital_and_analog_pin_status")
    digital_pin_request_frame_name           = compute_frame_name(process_name, "digital_pin_request")
    other_pin_request_frame_name             = compute_frame_name(process_name, "other_pin_request")

    :ok = Receiver.subscribe(self(), :ovcs, [alive_frame_name, digital_and_analog_pin_status_frame_name])

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
    {:ok, %{
      process_name: process_name,
      alive_frame_name: alive_frame_name,
      digital_and_analog_pin_status_frame_name: digital_and_analog_pin_status_frame_name,
      digital_pin_request_frame_name: digital_pin_request_frame_name,
      other_pin_request_frame_name: other_pin_request_frame_name,
      pins: @digital_pins |> Map.merge(@analog_pins)
    }}
  end

  @impl true
  def handle_info({:handle_frame,  %Frame{name: name, signals: signals}}, state) when name == state.digital_and_analog_pin_status_frame_name do
    pins = signals |> Enum.reduce(%{}, fn ({_, signal}, pins) ->
      Map.put(pins, signal.name, signal.value)
    end)
    {:noreply, %{state | pins: pins}}
  end

  @impl true
  def handle_info({:handle_frame,  %Frame{name: name} = _frame}, state) when name == state.alive_frame_name do
    {:noreply, state}
  end

  @impl true
  def handle_call({:set_digital_value, pin, value},  _from, state) do
    :ok = Emitter.update(:ovcs, state.digital_pin_request_frame_name, fn (data) ->
      %{data | "digital_pin#{pin}_enabled" => value}
    end)
    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:set_pwm_duty_cycle, pin, duty_cycle},  _from, state) do
    :ok = Emitter.update(:ovcs, state.pwm_pin_request_frame_name, fn (data) ->
      %{data | "pwm_pin#{pin}_duty_cycle" => duty_cycle}
    end)
    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:set_dac_duty_cycle, duty_cycle},  _from, state) do
    :ok = Emitter.update(:ovcs, state.other_pin_request_frame_name, fn (data) ->
      %{data | "dac_pin0_duty_cycle" => duty_cycle}
    end)
    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:get_digital_value, pin},  _from, state) do
    value = state.pins["digital_pin#{pin}_enabled"]
    {:reply, {:ok, value}, state}
  end

  @impl true
  def handle_call({:get_analog_value, pin},  _from, state) do
    value = state.pins["analog_pin#{pin}_value"]
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

  def get_analog_value(controller, pin) do
    GenServer.call(controller, {:get_analog_value, pin})
  end

  def get_digital_value(controller, pin) do
    GenServer.call(controller, {:get_digital_value, pin})
  end

  def start_adoption(controller_name) do
    :ok = Emitter.configure(:ovcs, "controller_configuration", %{
      parameters_builder_function: :default,
      initial_data: Application.vehicle_compposer().generic_controllers()[controller_name],
      enable: true
    })
  end

  def stop_adoption() do
    Emitter.disable(:ovcs, "controller_configuration")
  end

  defp compute_frame_name(process_name, suffix) do
    controller_name = Macro.underscore(process_name) |> String.split("/") |> List.last()
    "#{controller_name}_#{suffix}"
  end
end
