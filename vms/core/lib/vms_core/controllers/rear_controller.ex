defmodule VmsCore.Controllers.RearController do
  use GenServer

  alias Cantastic.{Frame, Signal, Emitter}

  @network_name :ovcs

  @rear_controller_request_frame_name "rear_controller_request"
  @rear_controller_status_frame_name "rear_controller_status"

  @main_negative_contactor "main_negative_contactor_enabled"
  @main_positive_contactor "main_positive_contactor_enabled"
  @precharge_contactor "precharge_contactor_enabled"
  @bms_ready_relay "bms_ready_enabled"
  @bms_charge_relay "bms_charge_enabled"

  @precharge_delay 5000
  @relay_operating_delay 50

  @impl true
  def init(_) do
    :ok = Cantastic.Receiver.subscribe(self(), @network_name, @rear_controller_status_frame_name)
    :ok = Emitter.configure(@network_name, @rear_controller_request_frame_name, %{
      parameters_builder_function: :default,
      initial_data: %{
        @main_negative_contactor   => false,
        @main_positive_contactor => false,
        @precharge_contactor => false,
        @bms_ready_relay => false,
        @bms_charge_relay => false
      }
    })
    Emitter.enable(@network_name, @rear_controller_request_frame_name)
    {:ok, %{
      main_negative_contactor_enabled: false,
      main_positive_contactor_enabled: false,
      precharge_contactor_enabled: false,
      bms_ready_enabled: false,
      bms_charge_enabled: false
    }}
  end

  def start_link(_) do
    GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  end

  @impl true
  def handle_info({:handle_frame,  %Frame{signals: signals}}, state) do
    %{
      @main_negative_contactor => %Signal{value: main_negative_contactor_enabled},
      @main_positive_contactor => %Signal{value: main_positive_contactor_enabled},
      @precharge_contactor     => %Signal{value: precharge_contactor_enabled},
      @bms_ready_relay         => %Signal{value: bms_ready_enabled},
      @bms_charge_relay        => %Signal{value: bms_charge_enabled},
    } = signals
    {:noreply, %{state |
    main_negative_contactor_enabled: main_negative_contactor_enabled,
    main_positive_contactor_enabled: main_positive_contactor_enabled,
    precharge_contactor_enabled: precharge_contactor_enabled,
    bms_ready_enabled: bms_ready_enabled,
    bms_charge_enabled: bms_charge_enabled
    }}
  end

  @impl true
  def handle_call(:ready_to_drive?,  _from, state) do
    ready = !state.precharge_contactor_enabled && state.main_negative_contactor_enabled && state.main_positive_contactor_enabled
    {:reply, {:ok, ready}, state}
  end

  def switch_on_bms_ready() do
    actuate_relay(@bms_ready_relay, true)
  end

  def switch_off_bms_ready() do
    actuate_relay(@bms_ready_relay, false)
  end

  def switch_on_bms_charge() do
    actuate_relay(@bms_charge_relay, true)
  end

  def switch_off_bms_charge() do
    actuate_relay(@bms_charge_relay, false)
  end

  def ready_to_drive?() do
    GenServer.call(__MODULE__, :ready_to_drive?)
  end

  def switch_on_high_voltage() do
    with :ok <- start_precharge(),
         _ <- :timer.sleep(@precharge_delay),
         :ok <- finish_precharge()
    do
      :ok
    else
      :unexpected -> :unexpected
    end
  end

  def switch_off_high_voltage() do
    with :ok <- disable_relay(@main_negative_contactor),
         :ok <- disable_relay(@precharge_contactor),
         :ok <- disable_relay(@main_positive_contactor)
    do
      :ok
    else
      :unexpected -> :unexpected
    end
  end

  defp start_precharge() do
    with :ok <- enable_relay(@main_negative_contactor),
         :ok <- enable_relay(@precharge_contactor)
    do
      :ok
    else
      :unexpected -> :unexpected
    end
  end

  defp finish_precharge() do
    with :ok <- enable_relay(@main_positive_contactor),
          _  <- :timer.sleep(@relay_operating_delay),
         :ok <- disable_relay(@precharge_contactor)
    do
      :ok
    else
      :unexpected -> :unexpected
    end
  end

  defp enable_relay(relay_name) do
    actuate_relay(relay_name, true)
  end

  defp disable_relay(relay_name) do
    actuate_relay(relay_name, false)
  end

  defp actuate_relay(relay_name, enable) do
    Emitter.update(@network_name, @rear_controller_request_frame_name, fn (data) ->
      %{data | relay_name => enable}
    end)
  end
end
