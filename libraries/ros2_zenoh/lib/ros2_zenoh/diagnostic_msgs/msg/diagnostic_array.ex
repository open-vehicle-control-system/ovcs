defmodule Ros2Zenoh.DiagnosticMsgs.Msg.DiagnosticArray do
  @moduledoc """
  ROS 2 `diagnostic_msgs/DiagnosticArray`: a header and one
  `DiagnosticStatus` per component, given as maps with `:level` (`:ok`,
  `:warn`, `:error` or `:stale`), `:name`, `:message`, `:hardware_id`
  and `:values` (`[{key, value}]`, strings).
  """

  import Ros2Zenoh.Cdr
  alias Ros2Zenoh.StdMsgs.Msg.Header

  defstruct header: %Header{}, status: []

  @dds_type "diagnostic_msgs::msg::dds_::DiagnosticArray_"
  @type_hash "RIHS01_5a8a36efb05fb25070fa0fb3810290c0e6cd4862b54a8fb975a1ee8dc55a333e"
  @levels %{ok: 0, warn: 1, error: 2, stale: 3}

  def dds_type, do: @dds_type
  def type_hash, do: @type_hash

  def encode(%__MODULE__{header: header, status: status}),
    do: sequence(Header.encode(header), status, &append_status/2)

  defp append_status(message, status) do
    message
    |> u8(Map.fetch!(@levels, status.level))
    |> string(status.name)
    |> string(Map.get(status, :message, ""))
    |> string(Map.get(status, :hardware_id, ""))
    |> sequence(Map.get(status, :values, []), fn encoded, {key, value} ->
      encoded |> string(key) |> string(value)
    end)
  end
end
