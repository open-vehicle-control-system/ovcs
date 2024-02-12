defmodule OvcsEcu.OvcsControllers.ContactorsController do
  alias Cantastic.Emitter

  @network_name "drive"
  @frame_name "contactorsStatusRequest"

  @main_negative_contactor "mainNegativeContactorEnabled"
  @main_positive_contactor "mainPositiveContactorEnabled"
  @precharge_contactor "prechargeContactorEnabled"

  @precharge_delay 5000
  @relay_operating_delay 50

  def init_emitters() do
    Emitter.configure(@network_name, @frame_name, %{
      parameters_builder_function: &contactors_state_request_frame_parameters/1,
      initial_data: %{
        @main_negative_contactor => false,
        @main_positive_contactor => false,
        @precharge_contactor     => false
      }
    })
    :ok
  end

  def contactors_state_request_frame_parameters(state) do
    {:ok, state.data, state}
  end

  def initialize() do
    Emitter.batch_enable(@network_name, [@frame_name])
  end

  def on() do
    with :ok <- start_precharge(),
         _ <- :timer.sleep(@precharge_delay),
         :ok <- finish_precharge()
    do
      :ok
    end
  end

  def off() do
    with :ok <- disable_contactor(@main_negative_contactor),
         :ok <- disable_contactor(@precharge_contactor),
         :ok <- disable_contactor(@main_positive_contactor)
    do
      :ok
    end
  end

  defp start_precharge() do
    with :ok <- enable_contactor(@main_negative_contactor),
         :ok <- enable_contactor(@precharge_contactor)
    do
      :ok
    end
  end

  defp finish_precharge() do
    with :ok <- enable_contactor(@main_positive_contactor),
          _  <- :timer.sleep(@relay_operating_delay),
         :ok <- disable_contactor(@precharge_contactor)
    do
      :ok
    end
  end

  defp enable_contactor(contactor_name) do
    actuate_contactor(contactor_name, true)
  end

  defp disable_contactor(contactor_name) do
    actuate_contactor(contactor_name, false)
  end

  defp actuate_contactor(contactor_name, enable) do
    Emitter.update(@network_name, @frame_name, fn (state) ->
      state |> put_in([:data, contactor_name], enable)
    end)
  end
end
