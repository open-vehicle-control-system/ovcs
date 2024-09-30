defmodule VmsCore.Controllers.GenericController do
  use GenServer

  alias Cantastic.{Frame, Signal, Emitter}
  alias VmsCore.PubSub

  def start_link(%{process_name: process_name} = args) do
    GenServer.start_link(__MODULE__, args, name: process_name)
  end

  @impl true
  def init(%{process_name:  process_name, control_digital_pins: control_digital_pins, control_other_pins: control_other_pins}) do
    alive_frame_name                         = compute_frame_name(process_name, "alive")
    digital_and_analog_pin_status_frame_name = compute_frame_name(process_name, "digital_and_analog_pin_status")
    digital_pin_request_frame_name           = compute_frame_name(process_name,  "digital_pin_request")
    other_pin_request_frame_name             = compute_frame_name(process_name,  "other_pin_request")

    :ok = Cantastic.Receiver.subscribe(self(), :ovcs, [alive_frame_name, digital_and_analog_pin_status_frame_name])

    if control_digital_pins do
      ok = Emitter.configure(:ovcs, digital_pin_request_frame_name, %{
        parameters_builder_function: :default,
        initial_data: %{
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
          "digital_pin20_enabled" => false,
        },
        enable: true
      })
    end

    if control_other_pins do
      ok = Emitter.configure(:ovcs, other_pin_request_frame_name, %{
        parameters_builder_function: :default,
        initial_data: %{
          "pwm_pin0_duty_cycle" => 0,
          "pwm_pin1_duty_cycle" => 0,
          "pwm_pin2_duty_cycle" => 0,
          "dac_pin0_duty_cycle" => 0
        },
        enable: true
      })
    end
    {:ok, %{
      process_name: process_name,
      alive_frame_name: alive_frame_name,
      digital_and_analog_pin_status_frame_name: digital_and_analog_pin_status_frame_name,
      digital_pin_request_frame_name: digital_pin_request_frame_name,
      other_pin_request_frame_name: other_pin_request_frame_name
    }}
  end

  @impl true # digital_and_analog_pin_status
  def handle_info({:handle_frame,  %Frame{signals: %{"digital_pin0_enabled" => _} = signals}}, state) do
    status = signals |> Enum.reduce(%{}, fn (signal, acc) ->
      %{acc | signal.name => signal.value}
    end)
    PubSub.broadcast("metrics", %PubSub.MetricMessage{name: :digital_and_analog_pin_status, value: status, source: state.process_name})
    {:noreply, state}
  end

  @impl true # alive
  def handle_info({:handle_frame,  %Frame{} = frame}, state) do
    {:noreply, state}
  end

  @impl true
  def handle_call({:actuate_digital_pin, pin, enable},  _from, state) do
    :ok = Emitter.update(:ovcs, state.digital_pin_request_frame_name, fn (data) ->
      %{data | "digital_pin#{pin}_enabled" => enable}
    end)
    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:set_pwm_pin, pin, duty_cycle},  _from, state) do
    :ok = Emitter.update(:ovcs, state.other_pin_request_frame_name, fn (data) ->
      %{data | "pwm_pin#{pin}_duty_cycle" => duty_cycle}
    end)
    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:set_dac_pin, duty_cycle},  _from, state) do
    :ok = Emitter.update(:ovcs, state.other_pin_request_frame_name, fn (data) ->
      %{data | "dac_pin0_duty_cycle" => duty_cycle}
    end)
    {:reply, :ok, state}
  end

  def actuate_digital_pin(pin, enable) do
    GenServer.call(__MODULE__, {:actuate_digital_pin, pin, enable})
  end

  def set_pwm_pin(pin, duty_cycle) do
    GenServer.call(__MODULE__, {:set_pwm_pin, pin, duty_cycle})
  end

  def set_dac_pin(duty_cycle) do
    GenServer.call(__MODULE__, {:set_dac_pin, duty_cycle})
  end

  defp compute_frame_name(process_name, suffix) do
    controller_name = Macro.underscore(process_name) |> String.split("/") |> List.last()
    "#{controller_name}_#{suffix}"
  end
end
