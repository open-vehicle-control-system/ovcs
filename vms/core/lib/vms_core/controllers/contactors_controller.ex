defmodule VmsCore.Controllers.ContactorsController do
  use GenServer

  require Logger
  alias Cantastic.Emitter

  @network_name :ovcs
  @status_request_frame_name "contactors_status_request"
  @status_frame_name "contactors_status"


  @main_negative_contactor "main_negative_contactor_enabled"
  @main_positive_contactor "main_positive_contactor_enabled"
  @precharge_contactor "precharge_contactor_enabled"

  @precharge_delay 5000
  @relay_operating_delay 50

  def start_link(_) do
    GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  end

  @impl true
  def init(_) do
    :ok = Cantastic.Receiver.subscribe(self(), @network_name, [@status_frame_name])
    :ok = Emitter.configure(@network_name, @status_request_frame_name, %{
      parameters_builder_function: &contactors_state_request_frame_parameters/1,
      initial_data: %{
        @main_negative_contactor => false,
        @main_positive_contactor => false,
        @precharge_contactor     => false
      }
    })
    :ok = Emitter.batch_enable(@network_name, [@status_request_frame_name])
    {:ok, %{
      main_negative_contactor_enabled: false,
      main_positive_contactor_enabled: false,
      precharge_contactor_enabled: false
    }}
  end

  defp contactors_state_request_frame_parameters(state) do
    {:ok, state.data, state}
  end

  @impl true
  def handle_info({:handle_frame,  _frame, [%{value: main_negative_contactor_enabled}, %{value: main_positive_contactor_enabled}, %{value: precharge_contactor_enabled}] = _signals}, state) do
    {:noreply, %{state |
        main_negative_contactor_enabled: main_negative_contactor_enabled,
        main_positive_contactor_enabled: main_positive_contactor_enabled,
        precharge_contactor_enabled: precharge_contactor_enabled
      }
    }
  end

  def handle_info({:handle_missing_frame,  frame_name}, state) do
    Logger.warning("Frame ovcs.#{frame_name} not emitted anymore")
    {:noreply, state}
  end

  @impl true
  def handle_call(:ready_to_drive?,  _from, state) do
    ready = !state.precharge_contactor_enabled && state.main_negative_contactor_enabled && state.main_positive_contactor_enabled
    {:reply, ready, state}
  end

  def ready_to_drive?() do
    GenServer.call(__MODULE__, :ready_to_drive?)
  end

  def on() do
    with :ok <- start_precharge(),
         _ <- :timer.sleep(@precharge_delay),
         :ok <- finish_precharge()
    do
      :ok
    else
      :unexpected -> :unexpected
    end
  end

  def off() do
    with :ok <- disable_contactor(@main_negative_contactor),
         :ok <- disable_contactor(@precharge_contactor),
         :ok <- disable_contactor(@main_positive_contactor)
    do
      :ok
    else
      :unexpected -> :unexpected
    end
  end

  defp start_precharge() do
    with :ok <- enable_contactor(@main_negative_contactor),
         :ok <- enable_contactor(@precharge_contactor)
    do
      :ok
    else
      :unexpected -> :unexpected
    end
  end

  defp finish_precharge() do
    with :ok <- enable_contactor(@main_positive_contactor),
          _  <- :timer.sleep(@relay_operating_delay),
         :ok <- disable_contactor(@precharge_contactor)
    do
      :ok
    else
      :unexpected -> :unexpected
    end
  end

  defp enable_contactor(contactor_name) do
    actuate_contactor(contactor_name, true)
  end

  defp disable_contactor(contactor_name) do
    actuate_contactor(contactor_name, false)
  end

  defp actuate_contactor(contactor_name, enable) do
    Emitter.update(@network_name, @status_request_frame_name, fn (state) ->
      state |> put_in([:data, contactor_name], enable)
    end)
  end
end
