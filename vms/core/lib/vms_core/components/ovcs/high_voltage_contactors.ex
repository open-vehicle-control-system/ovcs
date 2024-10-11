defmodule VmsCore.Components.OVCS.HighVoltageContactors do
  use GenServer
  alias VmsCore.{Bus, Components.OVCS.GenericController}

  @loop_period 10
  @relay_operating_delay 50

  def start_link(args) do
    GenServer.start_link(__MODULE__, args, name: __MODULE__)
  end

  @impl true
  def init(%{
    contact_source: contact_source,
    inverter_output_voltage_source: inverter_output_voltage_source,
    required_precharge_output_voltage: required_precharge_output_voltage,
    controller: controller,
    main_negative_relay_pin: main_negative_relay_pin,
    main_positive_relay_pin: main_positive_relay_pin,
    precharge_relay_pin: precharge_relay_pin})
  do
    Bus.subscribe("messages")
    {:ok, timer} = :timer.send_interval(@loop_period, :loop)
    {:ok, %{
      contact_source: contact_source,
      contact: :off,
      controller: controller,
      main_negative_relay_pin: main_negative_relay_pin,
      main_positive_relay_pin: main_positive_relay_pin,
      precharge_relay_pin: precharge_relay_pin,
      status: :off,
      inverter_output_voltage: 0,
      inverter_output_voltage_source: inverter_output_voltage_source,
      required_precharge_output_voltage: required_precharge_output_voltage,
      precharge_ending_timestamp: 0,
      loop_timer: timer,
      main_negative_relay_enabled: false,
      main_positive_relay_enabled: false,
      precharge_relay_enabled: false,
      ready_to_drive: false
    }}
  end

  @impl true
  def handle_info(:loop, state) do
    state = state
      |> toggle_contactors()
      |> check_ready_to_drive()
      |> emit_metrics()
    {:noreply, state}
  end

  def handle_info(%Bus.Message{name: :contact, value: contact, source: source}, state) when source == state.contact_source do
    {:noreply, %{state | contact: contact}}
  end
  def handle_info(%Bus.Message{name: :inverter_output_voltage, value: inverter_output_voltage, source: source}, state) when source == state.inverter_output_voltage_source do
    {:noreply, %{state | inverter_output_voltage: inverter_output_voltage}}
  end
  def handle_info(%Bus.Message{}, state) do # TODO, replace Bus ?
    {:noreply, state}
  end

  defp toggle_contactors(state) do
    state.required_precharge_output_voltage
    now = System.system_time(:millisecond)
    case {state.status, state.contact, state.inverter_output_voltage, state.precharge_ending_timestamp} do
      {:off, :start, _, _} ->
        start_precharge(state)
      {:starting, contact, inverter_output_voltage, _} when contact in [:on, :start] and inverter_output_voltage >= state.required_precharge_output_voltage ->
        end_precharge(state)
      {:precharge_complete, contact, _, precharge_ending_timestamp} when contact in [:on, :start] and precharge_ending_timestamp > now ->
        finish_precharge(state)
      {status, :off, _, _} when status != :off ->
        switch_off(state)
      _ ->
        state
    end
  end

  defp check_ready_to_drive(state) do
    {:ok, main_negative_relay_enabled} = GenericController.get_digital_value(state.controller, state.main_negative_relay_pin)
    {:ok, main_positive_relay_enabled} = GenericController.get_digital_value(state.controller, state.main_positive_relay_pin)
    {:ok, precharge_relay_enabled}     = GenericController.get_digital_value(state.controller, state.precharge_relay_pin)
    ready_to_drive = main_negative_relay_enabled && main_positive_relay_enabled && !precharge_relay_enabled
    %{state | ready_to_drive: ready_to_drive}
  end

  defp emit_metrics(state) do
    Bus.broadcast("messages", %Bus.Message{name: :main_negative_relay_enabled, value: state.main_negative_relay_enabled, source: __MODULE__})
    Bus.broadcast("messages", %Bus.Message{name: :main_positive_relay_enabled, value: state.main_positive_relay_enabled, source: __MODULE__})
    Bus.broadcast("messages", %Bus.Message{name: :precharge_relay_enabled, value: state.precharge_relay_enabled, source: __MODULE__})
    Bus.broadcast("messages", %Bus.Message{name: :ready_to_drive, value: state.ready_to_drive, source: __MODULE__})
    state
  end

  defp start_precharge(state) do
    :ok = enable_relay(state, :main_negative_relay_pin)
    :ok = enable_relay(state, :precharge_relay_pin)
    %{state | status: :starting}
  end

  defp end_precharge(state) do
    :ok = enable_relay(state, :main_positive_relay_pin)
    precharge_ending_timestamp = System.system_time(:millisecond) + @relay_operating_delay
    %{state | status: :precharge_complete, precharge_ending_timestamp: precharge_ending_timestamp}
  end

  defp finish_precharge(state) do
    :ok = disable_relay(state, :precharge_relay_pin)
    %{state | status: :started}
  end

  defp switch_off(state) do
    :ok = disable_relay(state, :precharge_relay_pin)
    :ok = disable_relay(state, :main_negative_relay_pin)
    :ok = disable_relay(state, :main_positive_relay_pin)
    %{state | status: :off}
  end

  defp enable_relay(state, relay) do
    set_relay(state, relay, true)
  end
  defp disable_relay(state, relay) do
    set_relay(state, relay, false)
  end
  defp set_relay(state, relay, value) do
    GenericController.set_digital_value(state.controller, Map.get(state, relay), value)
  end
end
