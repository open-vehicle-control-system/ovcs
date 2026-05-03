defmodule VmsCore.Vehicles.OBD2.Diagnostics do
  @moduledoc """
  Orchestrates the standard diagnostic services declared in
  `priv/can/vehicles/obd2.yml`.

  Subscribes to every cantastic OBD2 request, fans the decoded values
  out as VMS Bus metrics (so the dashboard's existing metrics channel
  picks them up automatically), and exposes `trigger_action/2` so the
  dashboard can request things on demand: re-read the VIN, clear DTCs,
  open an extended UDS session, etc.

  Live polling is permanently on for cheap data (Mode 01 fast/slow,
  Mode 03/07/0A DTCs); destructive or session-bound services
  (Mode 04, Mode 14, Mode 10, Mode 3E) are disabled at boot and only
  fired when explicitly triggered.
  """

  use GenServer
  require Logger

  alias Cantastic.OBD2
  alias VmsCore.Bus

  @network :obd2

  @always_on [
    "supported_pids",
    "live_data_fast",
    "live_data_slow",
    "stored_dtcs",
    "pending_dtcs",
    "permanent_dtcs",
    "uds_read_dtcs",
    "vehicle_info_vin",
    "vehicle_info_calibration_id",
    "vehicle_info_ecu_name"
  ]

  @on_demand [
    "clear_dtcs",
    "uds_clear_dtcs",
    "extended_session_powertrain",
    "tester_present_powertrain"
  ]

  def start_link(_) do
    GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  end

  @impl true
  def init(_) do
    Enum.each(@always_on ++ @on_demand, fn request ->
      OBD2.Request.subscribe(self(), @network, request)
    end)

    OBD2.Request.enable(@network, @always_on)

    {:ok,
     %{
       last_responses: %{},
       last_errors: %{},
       supported_pids: [],
       extended_session_open: false
     }}
  end

  @impl true
  def handle_info({:handle_obd2_response, %OBD2.Response{request_name: request_name} = response}, state) do
    state = put_in(state.last_responses[request_name], response)

    state =
      response
      |> broadcast_metrics(state)
      |> maybe_update_supported_pids(response)

    {:noreply, state}
  end

  def handle_info({:handle_obd2_error, error}, state) do
    Logger.warning("[OBD2.Diagnostics] negative response or decode error: #{inspect(error)}")
    state = record_error(state, error)
    {:noreply, state}
  end

  def handle_info({:disable, request_name}, state) do
    OBD2.Request.disable(@network, request_name)
    {:noreply, state}
  end

  defp record_error(state, {:nrc, _sid, _code, _name} = nrc) do
    put_in(state.last_errors[:last_nrc], nrc)
  end

  defp record_error(state, error), do: put_in(state.last_errors[:last_decode], error)

  defp broadcast_metrics(%OBD2.Response{request_name: name} = response, state)
       when name in ["live_data_fast", "live_data_slow"] do
    Enum.each(response.parameters, fn {param_name, %OBD2.Parameter{value: value}} ->
      Bus.broadcast("messages", %Bus.Message{
        name: String.to_atom(param_name),
        value: value,
        source: __MODULE__
      })
    end)

    state
  end

  defp broadcast_metrics(%OBD2.Response{request_name: "stored_dtcs", parameters: %{"dtcs" => p}}, state) do
    publish(:stored_dtcs, format_dtc_codes(p.value))
    publish(:stored_dtc_count, length(p.value))
    state
  end

  defp broadcast_metrics(%OBD2.Response{request_name: "pending_dtcs", parameters: %{"dtcs" => p}}, state) do
    publish(:pending_dtcs, format_dtc_codes(p.value))
    publish(:pending_dtc_count, length(p.value))
    state
  end

  defp broadcast_metrics(%OBD2.Response{request_name: "permanent_dtcs", parameters: %{"dtcs" => p}}, state) do
    publish(:permanent_dtcs, format_dtc_codes(p.value))
    publish(:permanent_dtc_count, length(p.value))
    state
  end

  defp broadcast_metrics(%OBD2.Response{request_name: "uds_read_dtcs", parameters: %{"dtc_records" => p}}, state) do
    formatted =
      p.value
      |> Enum.map(fn %{code: code, status: status} ->
        "#{code} (status 0x#{Integer.to_string(status, 16) |> String.upcase()})"
      end)
      |> format_lines()

    publish(:uds_dtcs, formatted)
    publish(:uds_dtc_count, length(p.value))
    state
  end

  defp broadcast_metrics(%OBD2.Response{request_name: "vehicle_info_vin", parameters: %{"vin" => p}}, state) do
    [vin | _] = p.value
    publish(:vin, String.trim(vin))
    state
  end

  defp broadcast_metrics(%OBD2.Response{request_name: "vehicle_info_calibration_id", parameters: %{"calibration_id" => p}}, state) do
    publish(:calibration_id, p.value |> Enum.map(&String.trim/1) |> format_lines())
    state
  end

  defp broadcast_metrics(%OBD2.Response{request_name: "vehicle_info_ecu_name", parameters: %{"ecu_name" => p}}, state) do
    [name | _] = p.value
    publish(:ecu_name, String.trim(name))
    state
  end

  defp broadcast_metrics(%OBD2.Response{request_name: "extended_session_powertrain", parameters: parameters}, state) do
    %{"p2_server_max_ms" => p2, "p2_star_server_max_ms" => p2_star} = parameters
    publish(:p2_server_max_ms, p2.value)
    publish(:p2_star_server_max_ms, p2_star.value)
    publish(:extended_session_open, true)
    %{state | extended_session_open: true}
  end

  defp broadcast_metrics(_response, state), do: state

  defp maybe_update_supported_pids(state, %OBD2.Response{request_name: "supported_pids", parameters: parameters}) do
    pids =
      [{0x00, "pids_01_to_20"}, {0x20, "pids_21_to_40"}, {0x40, "pids_41_to_60"},
       {0x60, "pids_61_to_80"}, {0x80, "pids_81_to_a0"}, {0xA0, "pids_a1_to_c0"},
       {0xC0, "pids_c1_to_e0"}]
      |> Enum.flat_map(fn {base, key} ->
        case parameters[key] do
          %OBD2.Parameter{raw_value: raw} -> VmsCore.Vehicles.OBD2.PidCatalog.decode_bitmask(raw, base)
          _ -> []
        end
      end)
      |> Enum.uniq()
      |> Enum.sort()

    publish(:supported_pids, pids)
    publish(:supported_pid_count, length(pids))
    %{state | supported_pids: pids}
  end

  defp maybe_update_supported_pids(state, _other), do: state

  defp publish(name, value) do
    Bus.broadcast("messages", %Bus.Message{name: name, value: value, source: __MODULE__})
  end

  defp format_dtc_codes([]), do: "No codes"
  defp format_dtc_codes(codes), do: Enum.join(codes, ", ")

  defp format_lines([]), do: "—"
  defp format_lines(lines), do: Enum.join(lines, "\n")

  # ── On-demand actions ────────────────────────────────────────────────

  @impl true
  def handle_cast({:pulse, request_name, duration_ms}, state) do
    OBD2.Request.enable(@network, request_name)
    Process.send_after(self(), {:disable, request_name}, duration_ms)
    {:noreply, state}
  end

  @impl true
  def handle_call(:open_extended_session, _from, state) do
    OBD2.Request.enable(@network, "extended_session_powertrain")
    OBD2.Request.enable(@network, "tester_present_powertrain")
    {:reply, :ok, state}
  end

  def handle_call(:close_extended_session, _from, state) do
    OBD2.Request.disable(@network, "tester_present_powertrain")
    OBD2.Request.disable(@network, "extended_session_powertrain")
    publish(:extended_session_open, false)
    {:reply, :ok, %{state | extended_session_open: false}}
  end

  # ── Public API surfaced to the dashboard via ActionsController ────────

  @doc """
  Fire `request_name` once (well, for `duration_ms` worth of cantastic's
  configured frequency) then disable it. Used for one-shot services like
  Mode 04 / Mode 14 clear-DTC where leaving the request enabled would
  spam the bus.
  """
  def pulse(request_name, duration_ms \\ 250) do
    GenServer.cast(__MODULE__, {:pulse, request_name, duration_ms})
  end

  def trigger_action("clear_dtcs", _params) do
    pulse("clear_dtcs")
    :ok
  end

  def trigger_action("uds_clear_dtcs", _params) do
    pulse("uds_clear_dtcs")
    :ok
  end

  def trigger_action("open_extended_session", _params) do
    GenServer.call(__MODULE__, :open_extended_session)
  end

  def trigger_action("close_extended_session", _params) do
    GenServer.call(__MODULE__, :close_extended_session)
  end
end
