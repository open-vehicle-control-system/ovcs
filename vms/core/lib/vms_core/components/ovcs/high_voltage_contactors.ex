defmodule VmsCore.Components.OVCS.HighVoltageContactors do
  @moduledoc """
  The high voltage contactors and their precharge, switched through a
  generic controller's digital pins.

  On a `:start` contact it closes the main negative and precharge
  relays; once the inverter's output voltage reaches
  `required_precharge_output_voltage_v` it closes the main positive relay,
  then opens the precharge relay. An `:off` contact opens all three.
  `:ready_to_drive` is true while both main relays read closed and the
  precharge relay open.

  ## Options

    * `:contact_source` — publishes the ignition `:contact`.
    * `:inverter_output_voltage_source` — publishes
      `:inverter_output_voltage`.
    * `:required_precharge_output_voltage_v` — the voltage at which precharge
      is complete.
    * `:controller` — the generic controller driving the relays.
    * `:main_negative_relay_pin`, `:main_positive_relay_pin`,
      `:precharge_relay_pin` — its digital pins.
  """
  use GenServer
  alias OvcsBus, as: Bus
  alias VmsCore.Components.OVCS.GenericController

  @loop_period_ms 10
  # Time for the main positive relay to close before precharge opens.
  @relay_operating_delay_ms 50

  def start_link(args) do
    GenServer.start_link(__MODULE__, args, name: __MODULE__)
  end

  @impl GenServer
  def init(%{
        contact_source: contact_source,
        inverter_output_voltage_source: inverter_output_voltage_source,
        required_precharge_output_voltage_v: required_precharge_output_voltage_v,
        controller: controller,
        main_negative_relay_pin: main_negative_relay_pin,
        main_positive_relay_pin: main_positive_relay_pin,
        precharge_relay_pin: precharge_relay_pin
      }) do
    Bus.subscribe("messages")
    {:ok, timer} = :timer.send_interval(@loop_period_ms, :loop)

    {:ok,
     %{
       contact_source: contact_source,
       contact: :off,
       controller: controller,
       main_negative_relay_pin: main_negative_relay_pin,
       main_positive_relay_pin: main_positive_relay_pin,
       precharge_relay_pin: precharge_relay_pin,
       status: :off,
       inverter_output_voltage: 0,
       inverter_output_voltage_source: inverter_output_voltage_source,
       required_precharge_output_voltage_v: required_precharge_output_voltage_v,
       precharge_ending_time_ms: 0,
       loop_timer: timer,
       main_negative_relay_enabled: false,
       main_positive_relay_enabled: false,
       precharge_relay_enabled: false,
       ready_to_drive: false
     }}
  end

  @impl GenServer
  def handle_info(:loop, state) do
    state =
      state
      |> toggle_contactors()
      |> check_ready_to_drive()
      |> emit_metrics()

    {:noreply, state}
  end

  def handle_info(%Bus.Message{name: :contact, value: contact, source: source}, state)
      when source == state.contact_source do
    {:noreply, %{state | contact: contact}}
  end

  def handle_info(
        %Bus.Message{
          name: :inverter_output_voltage,
          value: inverter_output_voltage,
          source: source
        },
        state
      )
      when source == state.inverter_output_voltage_source do
    {:noreply, %{state | inverter_output_voltage: inverter_output_voltage}}
  end

  def handle_info(%Bus.Message{}, state) do
    {:noreply, state}
  end

  defp toggle_contactors(state) do
    now_ms = System.monotonic_time(:millisecond)

    case {state.status, state.contact, state.inverter_output_voltage,
          state.precharge_ending_time_ms} do
      {:off, :start, _, _} ->
        start_precharge(state)

      {:starting, contact, inverter_output_voltage, _}
      when contact in [:on, :start] and
             inverter_output_voltage >= state.required_precharge_output_voltage_v ->
        end_precharge(state)

      {:precharge_complete, contact, _, precharge_ending_time_ms}
      when contact in [:on, :start] and now_ms >= precharge_ending_time_ms ->
        finish_precharge(state)

      {status, :off, _, _} when status != :off ->
        switch_off(state)

      _ ->
        state
    end
  end

  defp check_ready_to_drive(state) do
    {:ok, main_negative_relay_enabled} =
      GenericController.get_digital_value(state.controller, state.main_negative_relay_pin)

    {:ok, main_positive_relay_enabled} =
      GenericController.get_digital_value(state.controller, state.main_positive_relay_pin)

    {:ok, precharge_relay_enabled} =
      GenericController.get_digital_value(state.controller, state.precharge_relay_pin)

    ready_to_drive =
      main_negative_relay_enabled && main_positive_relay_enabled && !precharge_relay_enabled

    %{state | ready_to_drive: ready_to_drive}
  end

  defp emit_metrics(state) do
    Bus.broadcast("messages", %Bus.Message{
      name: :ready_to_drive,
      value: state.ready_to_drive,
      source: __MODULE__
    })

    state
  end

  defp start_precharge(state) do
    :ok = enable_relay(state, :main_negative_relay_pin)
    :ok = enable_relay(state, :precharge_relay_pin)
    %{state | status: :starting}
  end

  defp end_precharge(state) do
    :ok = enable_relay(state, :main_positive_relay_pin)
    # Monotonic: the wall clock steps when NTP first synchronises.
    precharge_ending_time_ms = System.monotonic_time(:millisecond) + @relay_operating_delay_ms
    %{state | status: :precharge_complete, precharge_ending_time_ms: precharge_ending_time_ms}
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

  defp enable_relay(state, relay_pin_key) do
    set_relay(state, relay_pin_key, true)
  end

  defp disable_relay(state, relay_pin_key) do
    set_relay(state, relay_pin_key, false)
  end

  defp set_relay(state, relay_pin_key, enabled) do
    GenericController.set_digital_value(state.controller, Map.get(state, relay_pin_key), enabled)
  end
end
