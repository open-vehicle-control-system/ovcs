defmodule VintageNetWiFi.Event do
  @moduledoc ~S"""
  WiFi events.

  Currently supported:
  * `CTRL-EVENT-ASSOC-REJECT` - occurs when authentication fails
  * `CTRL-EVENT-SSID-TEMP-DISABLED` - association with SSID is temporarily blocked by `wpa_supplicant` in some cases.
  * `CTRL-EVENT-SSID-REENABLED` - matching event when SSID is re-enabled.

  All events have a `:name`, and the other fields are optional.
  * `CTRL-EVENT-ASSOC-REJECT`
    * `:bssid` - a unique address for the access point
    * `:status_code` - status code of the event
  * `CTRL-EVENT-SSID-TEMP-DISABLED`
    * `:id` - event identifier?
    * `:ssid` - the access point's name
    * `:auth_failures` - how many failures occured to lead to disabling
    * `:duration` - time of block in seconds
    * `:reason` - why the SSID is disabled
  * `CTRL-EVENT-SSID-REENABLED`
    * `:id` - event identifier?
    * `:ssid` - the access point's name

  ## Examples:

      iex> VintageNetWiFi.Event.new("CTRL-EVENT-ASSOC-REJECT", %{"bssid" => "ab:cd:ef:01:02:03", "status_code" => "1"})
      %VintageNetWiFi.Event{
        name: "CTRL-EVENT-ASSOC-REJECT",
        bssid: "ab:cd:ef:01:02:03",
        status_code: 1
      }
  """

  @enforce_keys [:name]

  defstruct [:name, :bssid, :status_code, :id, :ssid, :auth_failures, :duration, :reason]

  @known_params [
    "name",
    "bssid",
    "status_code",
    "id",
    "ssid",
    "auth_failures",
    "duration",
    "reason"
  ]

  @typedoc """
  WiFi event structure.
  """
  @type t :: %__MODULE__{
          name: nil | String.t(),
          bssid: nil | String.t(),
          status_code: nil | non_neg_integer(),
          id: nil | non_neg_integer(),
          ssid: String.t(),
          auth_failures: nil | non_neg_integer(),
          duration: nil | non_neg_integer(),
          reason: nil | String.t()
        }

  @doc """
  Create an event with the appropriate fields
  """
  @spec new(String.t(), %{optional(String.t()) => String.t() | non_neg_integer()}) ::
          VintageNetWiFi.Event.t()
  def new(name, params)

  def new("CTRL-EVENT-ASSOC-REJECT" = name, params) do
    params = sanitize_params(params)
    event = struct(__MODULE__, params)

    %__MODULE__{event | name: name}
  end

  def new("CTRL-EVENT-SSID-REENABLED" = name, params) do
    params = sanitize_params(params)
    event = struct(__MODULE__, params)

    %__MODULE__{event | name: name}
  end

  def new("CTRL-EVENT-SSID-TEMP-DISABLED" = name, params) do
    params = sanitize_params(params)
    event = struct(__MODULE__, params)

    %__MODULE__{event | name: name}
  end

  def new("CTRL-EVENT-NETWORK-NOT-FOUND" = name, _params) do
    %__MODULE__{name: name}
  end

  @integer_keys [
    "status_code",
    "id",
    "auth_failures",
    "duration"
  ]

  defp sanitize_params(params) when is_map(params) do
    params
    |> Map.take(@known_params)
    |> Map.new(fn
      {key, value} when key in @integer_keys ->
        {String.to_existing_atom(key), String.to_integer(value)}

      {key, value} ->
        {String.to_existing_atom(key), value}
    end)
  end
end
