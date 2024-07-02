defmodule VmsCore.FrontController do
  use GenServer
  alias Cantastic.{Emitter}

  @network_name :ovcs
  @digital_pin_request_frame_name "front_controller_digital_pin_request"

  @impl true
  def init(_) do
    :ok = Emitter.configure(@network_name, @digital_pin_request_frame_name, %{
      parameters_builder_function: &digital_pin_request_frame_parameter_builder/1,
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
    Emitter.enable(@network_name, @digital_pin_request_frame_name)
    {:ok, %{}}
  end

  def start_link(_) do
    GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  end

  defp digital_pin_request_frame_parameter_builder(data) do
    {:ok, data, data}
  end

  def set_pin(pin_number, value) do
    :ok = Emitter.update(@network_name, @digital_pin_request_frame_name, fn (data) ->
      %{data | "digital_pin" <> pin_number <> "_enabled" => value}
    end)
  end
end
