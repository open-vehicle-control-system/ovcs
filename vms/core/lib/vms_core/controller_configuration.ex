defmodule VmsCore.ControllerConfiguration do
  use GenServer
  alias Cantastic.{Emitter}

  @network_name :ovcs
  @configuration_frame_name "controller_configuration"

  @impl true
  def init(_) do
    :ok = Emitter.configure(@network_name, @configuration_frame_name, %{
      parameters_builder_function: &configuration_frame_parameter_builder/1,
      initial_data: %{
        "current_controller" => nil,
        "configurations" => controller_configurations()
      }
    })
    {:ok, %{}}
  end

  def start_link(_) do
    GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  end

  def start(controller_name) do
    :ok = Emitter.update(@network_name, @configuration_frame_name, fn (data) ->
      %{data | "current_controller" => controller_name}
    end)
    Emitter.enable(@network_name, @configuration_frame_name)
  end

  def stop() do
    Emitter.disable(@network_name, @configuration_frame_name)
  end

  defp configuration_frame_parameter_builder(data) do
    parameters = data["configurations"][data["current_controller"]]
    {:ok, parameters, data}
  end

  defp controller_configurations() do
    %{
      "front_controller" => %{
        "controller_id" => 0,
        "digital_pin0" => "read_write",
        "digital_pin1" => "read_write",
        "digital_pin2" => "read_write",
        "digital_pin3" => "read_write",
        "digital_pin4" => "read_write",
        "digital_pin5" => "read_write",
        "digital_pin6" => "read_write",
        "digital_pin7" => "read_write",
        "digital_pin8" => "read_write",
        "digital_pin9" => "read_write",
        "digital_pin10" => "read_write",
        "digital_pin11" => "read_write",
        "digital_pin12" => "read_write",
        "digital_pin13" => "read_write",
        "digital_pin14" => "disabled",
        "digital_pin15" => "disabled",
        "digital_pin16" => "disabled",
        "digital_pin17" => "disabled",
        "digital_pin18" => "disabled",
        "digital_pin19" => "disabled",
        "digital_pin20" => "disabled",
        "pwm_pin0" => "enabled",
        "pwm_pin1" => "enabled",
        "pwm_pin2" => "enabled",
        "dac_pin0" => "enabled",
        "analog_pin0" => "enabled",
        "analog_pin1" => "enabled",
        "analog_pin2" => "enabled"
      }
    }
  end
end
