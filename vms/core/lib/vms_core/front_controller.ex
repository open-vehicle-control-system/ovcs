defmodule VmsCore.FrontController do
  use GenServer
  alias Cantastic.{Emitter, Frame}

  @network_name :ovcs
  @digital_pin_request_frame_name "front_controller_digital_pin_request"
  @other_pin_request_frame_name "front_controller_other_pin_request"
  @digital_and_analog_pins_status_frame_name "front_controller_digital_and_analog_pins_status"

  @impl true
  def init(_) do
    :ok = Emitter.configure(@network_name, @digital_pin_request_frame_name, %{
      parameters_builder_function: &pin_request_frame_parameter_builder/1,
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
      }
    })
    :ok = Emitter.configure(@network_name, @other_pin_request_frame_name, %{
      parameters_builder_function: &pin_request_frame_parameter_builder/1,
      initial_data: %{
          "pwm_pin0_duty_cycle" => 0,
          "pwm_pin1_duty_cycle" => 0,
          "pwm_pin2_duty_cycle" => 0,
          "dac_pin0_duty_cycle" => 0
      }
    })
    Emitter.enable(@network_name, [@digital_pin_request_frame_name, @other_pin_request_frame_name])
    ok = Cantastic.Receiver.subscribe(self(), @network_name, @digital_and_analog_pins_status_frame_name)
    {:ok, %{}}
  end

  def start_link(_) do
    GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  end

  @impl true
  def handle_info({:handle_frame,  %Frame{signals: signals}}, state) do
    IO.inspect "----------"
    IO.inspect signals["analog_pin0_value"].value
    IO.inspect signals["analog_pin1_value"].value
    IO.inspect signals["analog_pin2_value"].value
    {:noreply, state}
  end

  defp pin_request_frame_parameter_builder(data) do
    {:ok, data, data}
  end

  def set_pin(pin_number, value) do
    :ok = Emitter.update(@network_name, @digital_pin_request_frame_name, fn (data) ->
      %{data | "digital_pin" <> pin_number <> "_enabled" => value}
    end)
  end

  def set_pwm(pin_number, duty_cycle) do
    :ok = Emitter.update(@network_name, @other_pin_request_frame_name, fn (data) ->
      %{data | "pwm_pin" <> pin_number <> "_duty_cycle" => duty_cycle}
    end)
  end

  def set_dac(duty_cycle) do
    :ok = Emitter.update(@network_name, @other_pin_request_frame_name, fn (data) ->
      %{data | "dac_pin0_duty_cycle" => duty_cycle}
    end)
  end
end
