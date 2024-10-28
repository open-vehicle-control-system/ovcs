defmodule VintageNetWiFi.BSSIDRequester do
  @moduledoc """
  Request access point information asynchronously

  Getting access point information is important, but it's easy to fall
  behind and start blocking more important requests. This GenServer
  handles this separate from the main WPASupplicant GenServer.
  """
  use GenServer

  alias VintageNetWiFi.{WPASupplicantDecoder, WPASupplicantLL}
  require Logger

  @doc """
  Start a GenServer

  Arguments:

  * `:ll` - the WPASupplicantLL GenServer pid
  * `:notification_pid` - where to send response messages
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(init_args) do
    GenServer.start_link(__MODULE__, init_args)
  end

  @doc """
  Get info on all known access points

  This is the get everything all at once call. Everything is sent back.
  If it's not known, then it's not known.
  """
  @spec get_all_access_points(GenServer.server(), any()) :: :ok
  def get_all_access_points(server, cookie) when not is_nil(server) do
    GenServer.cast(server, {:get_all_access_points, cookie})
  end

  @doc """
  Request information on a BSSID or an access point index

  The response comes back to the process that started this GenServer with the
  details.
  """
  @spec get_access_point_info(GenServer.server(), String.t() | non_neg_integer(), any()) :: :ok
  def get_access_point_info(server, index_or_bssid, cookie) when not is_nil(server) do
    GenServer.cast(server, {:get_access_point_info, index_or_bssid, cookie})
  end

  @doc """
  Don't bother looking up AP info

  This request doesn't do anything but send back a message to remove an access point.
  It's needed for flushing out data returned asynchronously from `get_access_point_info/2`
  calls
  """
  @spec forget_access_point_info(GenServer.server(), String.t() | non_neg_integer(), any()) :: :ok
  def forget_access_point_info(server, index_or_bssid, cookie) when not is_nil(server) do
    GenServer.cast(server, {:forget_access_point_info, index_or_bssid, cookie})
  end

  @impl GenServer
  def init(init_args) do
    state = %{
      ll: Keyword.fetch!(init_args, :ll),
      notification_pid: Keyword.fetch!(init_args, :notification_pid)
    }

    {:ok, state}
  end

  @impl GenServer
  def handle_cast({:get_all_access_points, cookie}, state) do
    all_bss = get_all_bss(state)
    send_result(state, all_bss, cookie)
    {:noreply, state}
  end

  def handle_cast({:get_access_point_info, index_or_bssid, cookie}, state) do
    case make_bss_request(state, index_or_bssid) do
      {:ok, ap_or_peer} ->
        send_result(state, ap_or_peer, cookie)

      {:error, reason} ->
        Logger.warning(
          "Ignoring error getting info on BSSID #{inspect(index_or_bssid)}: #{inspect(reason)}"
        )
    end

    {:noreply, state}
  end

  def handle_cast({:forget_access_point_info, index_or_bssid, cookie}, state) do
    send_result(state, index_or_bssid, cookie)
    {:noreply, state}
  end

  defp send_result(state, result, cookie) do
    send(state.notification_pid, {:bssid_result, result, cookie})
  end

  defp get_all_bss(state) do
    get_all_bss(state, 0, %{})
  end

  defp get_all_bss(state, index, acc) do
    case make_bss_request(state, index) do
      {:ok, ap} ->
        get_all_bss(state, index + 1, Map.put(acc, ap.bssid, ap))

      _error ->
        acc
    end
  end

  defp make_bss_request(state, index_or_bssid) do
    case WPASupplicantLL.control_request(state.ll, "BSS #{index_or_bssid}") do
      {:ok, raw_response} ->
        raw_response
        |> WPASupplicantDecoder.decode_kv_response()
        |> decode_bss_response()

      error ->
        error
    end
  end

  defp decode_bss_response(%{"mesh_id" => _} = mesh_response) do
    {:ok, VintageNetWiFi.MeshPeer.new(mesh_response)}
  end

  defp decode_bss_response(%{
         "freq" => frequency_string,
         "level" => level_string,
         "flags" => flags_string,
         "ssid" => ssid,
         "bssid" => bssid
       }) do
    frequency = String.to_integer(frequency_string)
    flags = WPASupplicantDecoder.parse_flags(flags_string)
    signal_dbm = String.to_integer(level_string)

    {:ok, VintageNetWiFi.AccessPoint.new(bssid, ssid, frequency, signal_dbm, flags)}
  end

  defp decode_bss_response(_other) do
    {:error, :unknown}
  end
end
