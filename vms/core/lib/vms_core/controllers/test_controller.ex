defmodule VmsCore.Controllers.TestController do
  use GenServer

  alias Cantastic.{Frame, Signal, Emitter}

  @network_name :ovcs

  # "test_controller_alive"
# "test_controller_digital_pin_request"
# "test_controller_other_pin_request"
# "test_controller_pin_status"

  @impl true
  def init(_) do
    :ok = Cantastic.Receiver.subscribe(self(), @network_name,"test_controller_pin_status")
    :ok = Emitter.configure(@network_name, "test_controller_digital_pin_request", %{
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
      }
    })
    Emitter.enable(@network_name, "test_controller_digital_pin_request")
    {:ok, %{}}
  end

  def start_link(_) do
    GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  end

  @impl true
  def handle_info({:handle_frame,  %Frame{signals: _signals}}, state) do
    {:noreply, state}
  end

  def on() do
    actuate_all_relays(true)
  end
  def on(pin) do
    actuate_relay("digital_pin#{pin}_enabled" , true)
  end

  def off() do
    actuate_all_relays(false)
  end
  def off(pin) do
    actuate_relay("digital_pin#{pin}_enabled" , false)
  end


  defp actuate_relay(relay_name, enable) do
    Emitter.update(@network_name, "test_controller_digital_pin_request", fn (data) ->
      %{data | relay_name => enable}
    end)
  end

  defp actuate_all_relays(enable) do
    Emitter.update(@network_name, "test_controller_digital_pin_request", fn (data) ->
      %{data | "digital_pin0_enabled" => enable,
        "digital_pin1_enabled" => enable,
        "digital_pin2_enabled" => enable,
        "digital_pin3_enabled" => enable,
        "digital_pin4_enabled" => enable,
        "digital_pin5_enabled" => enable,
        "digital_pin6_enabled" => enable,
        "digital_pin7_enabled" => enable,
        "digital_pin8_enabled" => enable,
        "digital_pin9_enabled" => enable,
        "digital_pin10_enabled" => enable,
        "digital_pin11_enabled" => enable,
        "digital_pin12_enabled" => enable,
        "digital_pin13_enabled" => enable,
        "digital_pin14_enabled" => enable,
        "digital_pin15_enabled" => enable,
        "digital_pin16_enabled" => enable,
        "digital_pin17_enabled" => enable,
        "digital_pin18_enabled" => enable,
        "digital_pin19_enabled" => enable,
        "digital_pin20_enabled" => enable,
    }
    end)
  end
end
