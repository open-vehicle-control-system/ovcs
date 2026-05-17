defmodule Obd2.Vms.Discovery do
  @moduledoc """
  Bus discovery and proprietary-data probing.

  Two jobs in one process:

  1. **Passive sniffing** — opens a raw socket on the OBD2 network and
     watches every frame on the bus. Builds a per-ID summary
     (count, last raw data, last seen at) and republishes it as a single
     `:bus_traffic` Bus metric so the dashboard can show "what's
     chatting" without having to declare every frame in YAML.

  2. **Active UDS DID probing** — on demand, walks ISO 14229-1's standard
     ECU identification DID range (and any caller-supplied range) on the
     `0x7E0/0x7E8` powertrain ECU using a dedicated ISO-TP socket. DIDs
     that come back with a positive response (`0x62`) are surfaced as
     ASCII text + raw hex under `:uds_dids`.

  Probing is intentionally rate-limited (50 ms per DID, single in-flight
  request, ~3 s total budget for the standard range) so we never flood
  the bus or step on cantastic's own request loops.
  """

  use GenServer
  require Logger

  alias Cantastic.{ConfigurationStore, Socket, SocketMessage}
  alias OvcsBus, as: Bus

  @network :obd2
  @id_mask 0x1FFFFFFF
  @passive_publish_interval_ms 1_000

  # Default DID range probed by `start_did_scan/0`: ISO 14229-1's
  # ECU identification block. Manufacturers tend to populate at least
  # F190 (VIN), F18C (ECU serial) and F195 (supplier SW version), and
  # most expose half a dozen of the others — useful for fingerprinting
  # an unknown ECU.
  @default_did_range Enum.to_list(0xF180..0xF19E)

  # Powertrain ECU diagnostic frame pair. Most modern vehicles answer
  # Mode 22 here. For a multi-ECU scan, callers can pass a different
  # pair to `start_did_scan/1`.
  @default_request_id 0x7E0
  @default_response_id 0x7E8

  @did_request_interval_ms 50
  @did_request_timeout_ms 200

  def start_link(_) do
    GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  end

  @impl true
  def init(_) do
    state = %{
      passive_socket: nil,
      passive_task: nil,
      seen: %{},
      did_socket: nil,
      did_results: %{},
      did_scan_running: false
    }

    {:ok, state, {:continue, :start_passive}}
  end

  @impl true
  def handle_continue(:start_passive, state) do
    case interface_for(@network) do
      {:ok, interface} ->
        case Socket.bind_raw(interface) do
          {:ok, socket} ->
            task = Task.async(fn -> passive_loop(socket, self()) end)
            schedule_publish()
            {:noreply, %{state | passive_socket: socket, passive_task: task}}

          {:error, reason} ->
            Logger.warning("[OBD2.Discovery] passive sniffing disabled (#{inspect(reason)})")
            {:noreply, state}
        end

      {:error, reason} ->
        Logger.warning("[OBD2.Discovery] no interface for :obd2 network (#{inspect(reason)})")
        {:noreply, state}
    end
  end

  defp passive_loop(socket, parent) do
    case Socket.receive_message(socket) do
      {:ok, %SocketMessage{raw: raw}} ->
        case parse_frame(raw) do
          {:ok, id, data} -> send(parent, {:passive_frame, id, data})
          :ignore -> :ok
        end

      _ ->
        :ok
    end

    passive_loop(socket, parent)
  end

  defp parse_frame(<<id_and_flags::little-integer-size(32),
                     byte_number::little-integer-size(8),
                     _unused::binary-size(3),
                     payload::binary-size(byte_number),
                     _rest::binary>>) do
    {:ok, Bitwise.band(id_and_flags, @id_mask), payload}
  end

  defp parse_frame(_other), do: :ignore

  @impl true
  def handle_info({:passive_frame, id, data}, state) do
    now = System.monotonic_time(:millisecond)

    seen =
      Map.update(state.seen, id, %{count: 1, last: data, last_seen: now}, fn entry ->
        %{entry | count: entry.count + 1, last: data, last_seen: now}
      end)

    {:noreply, %{state | seen: seen}}
  end

  def handle_info(:publish_passive, state) do
    schedule_publish()
    publish_traffic(state.seen)
    {:noreply, state}
  end

  def handle_info({ref, _result}, state) when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    {:noreply, state}
  end

  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state), do: {:noreply, state}

  def handle_info({:probe_did, [], _request_id, _response_id}, state) do
    publish_did_results(state.did_results)
    publish_did_status("Scan finished — #{map_size(state.did_results)} DIDs answered")
    if state.did_socket, do: :socket.close(state.did_socket)
    {:noreply, %{state | did_socket: nil, did_scan_running: false}}
  end

  def handle_info({:probe_did, [did | rest], request_id, response_id}, %{did_socket: socket} = state) do
    payload = <<0x22, did::big-integer-size(16)>>
    state =
      case Socket.send(socket, payload) do
        :ok -> receive_did_response(state, did, socket)
        {:error, _} -> state
      end

    Process.send_after(self(), {:probe_did, rest, request_id, response_id}, @did_request_interval_ms)
    {:noreply, state}
  end

  defp schedule_publish do
    Process.send_after(self(), :publish_passive, @passive_publish_interval_ms)
  end

  defp publish_traffic(seen) do
    summary =
      seen
      |> Enum.sort_by(fn {id, _} -> id end)
      |> Enum.map(fn {id, %{count: count, last: last}} ->
        "0x#{hex(id, 3)}  ×#{count}  #{format_bytes(last)}"
      end)
      |> case do
        [] -> "No frames observed yet"
        rows -> Enum.join(rows, "\n")
      end

    Bus.broadcast("messages", %Bus.Message{name: :bus_traffic, value: summary, source: __MODULE__})
    Bus.broadcast("messages", %Bus.Message{name: :bus_unique_ids, value: map_size(seen), source: __MODULE__})
  end

  # ── Active DID scan ──────────────────────────────────────────────────

  @impl true
  def handle_call({:start_did_scan, _dids, _request_id, _response_id}, _from, %{did_scan_running: true} = state) do
    {:reply, {:error, :already_running}, state}
  end

  def handle_call({:start_did_scan, dids, request_id, response_id}, _from, state) do
    case interface_for(@network) do
      {:ok, interface} ->
        case Socket.bind_isotp(interface, request_id, response_id, 0x0) do
          {:ok, socket} ->
            send(self(), {:probe_did, dids, request_id, response_id})
            new_state = %{state | did_socket: socket, did_scan_running: true, did_results: %{}}
            publish_did_status("Scanning #{length(dids)} DIDs at 0x#{hex(request_id, 3)}/0x#{hex(response_id, 3)}…")
            {:reply, :ok, new_state}

          {:error, reason} ->
            Logger.warning("[OBD2.Discovery] DID scan ISO-TP bind failed: #{inspect(reason)}")
            {:reply, {:error, reason}, state}
        end

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  defp receive_did_response(state, did, socket) do
    parent = self()
    ref = make_ref()

    waiter =
      spawn_link(fn ->
        result =
          case Socket.receive_message(socket) do
            {:ok, %SocketMessage{raw: raw}} -> {:ok, raw}
            other -> other
          end

        send(parent, {:did_response, ref, did, result})
      end)

    receive do
      {:did_response, ^ref, ^did, {:ok, raw}} ->
        store_did_response(state, did, raw)
    after
      @did_request_timeout_ms ->
        Process.exit(waiter, :kill)
        state
    end
  end

  defp store_did_response(state, did, <<0x62, did_high::8, did_low::8, payload::binary>>) do
    case <<did_high, did_low>> do
      <<^did::big-integer-size(16)>> ->
        %{state | did_results: Map.put(state.did_results, did, payload)}

      _ ->
        state
    end
  end

  defp store_did_response(state, _did, _other), do: state

  defp publish_did_results(results) do
    rendered =
      results
      |> Enum.sort_by(fn {did, _} -> did end)
      |> Enum.map(fn {did, payload} ->
        "0x#{hex(did, 4)}  #{format_did(payload)}"
      end)
      |> case do
        [] -> "No DIDs responded"
        rows -> Enum.join(rows, "\n")
      end

    Bus.broadcast("messages", %Bus.Message{name: :uds_dids, value: rendered, source: __MODULE__})
    Bus.broadcast("messages", %Bus.Message{name: :uds_did_count, value: map_size(results), source: __MODULE__})
  end

  defp publish_did_status(text) do
    Bus.broadcast("messages", %Bus.Message{name: :discovery_status, value: text, source: __MODULE__})
  end

  defp format_did(<<>>), do: "(empty)"

  defp format_did(payload) do
    ascii = printable_ascii(payload)
    hex = format_bytes(payload)

    if ascii == "" do
      hex
    else
      "#{ascii}   [#{hex}]"
    end
  end

  defp printable_ascii(bytes) do
    bytes
    |> :binary.bin_to_list()
    |> Enum.map(fn
      b when b in 0x20..0x7E -> b
      _ -> ?.
    end)
    |> :binary.list_to_bin()
    |> String.trim_trailing(".")
  end

  defp format_bytes(bytes) do
    bytes
    |> :binary.bin_to_list()
    |> Enum.map_join(" ", &hex(&1, 2))
  end

  defp hex(value, width) do
    value |> Integer.to_string(16) |> String.pad_leading(width, "0") |> String.upcase()
  end

  defp interface_for(network_name) do
    case Enum.find(ConfigurationStore.networks(), fn n -> n.network_name == network_name end) do
      nil -> {:error, :network_not_configured}
      %{interface: interface} -> {:ok, interface}
    end
  end

  # ── Public API ───────────────────────────────────────────────────────

  @doc """
  Triggers a UDS Mode 0x22 walk over `dids` (defaults to ISO 14229-1's
  standard ECU identification range 0xF180–0xF19E) on the configured
  ECU pair (defaults to powertrain 0x7E0 / 0x7E8).
  """
  def start_did_scan(opts \\ []) do
    dids = opts[:dids] || @default_did_range
    request_id = opts[:request_id] || @default_request_id
    response_id = opts[:response_id] || @default_response_id
    GenServer.call(__MODULE__, {:start_did_scan, dids, request_id, response_id})
  end

  def trigger_action("scan_dids", _params) do
    case start_did_scan() do
      :ok -> :ok
      {:error, :already_running} -> :ok
      {:error, _other} -> :ok
    end
  end
end
