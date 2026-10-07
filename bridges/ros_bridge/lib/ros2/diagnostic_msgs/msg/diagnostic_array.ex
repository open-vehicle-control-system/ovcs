defmodule Ros2.DiagnosticMsgs.Msg.DiagnosticArray do
  @moduledoc """
  ROS 2 `diagnostic_msgs/DiagnosticArray`: a header and one
  `DiagnosticStatus` per component, given as maps with `:level` (`:ok`,
  `:warn`, `:error` or `:stale`), `:name`, `:message`, `:hardware_id`
  and `:values` (`[{key, value}]`, strings).
  """

  import Ros2.Cdr
  alias Ros2.StdMsgs.Msg.Header

  defstruct header: %Header{}, status: []

  @dds_type "diagnostic_msgs::msg::dds_::DiagnosticArray_"
  @type_hash "RIHS01_5a8a36efb05fb25070fa0fb3810290c0e6cd4862b54a8fb975a1ee8dc55a333e"
  @levels %{ok: 0, warn: 1, error: 2, stale: 3}

  def dds_type, do: @dds_type
  def type_hash, do: @type_hash

  def encode(%__MODULE__{header: header, status: status}),
    do: sequence(Header.encode(header), status, &status/2)

  defp status(acc, s) do
    acc
    |> u8(Map.fetch!(@levels, s.level))
    |> string(s.name)
    |> string(Map.get(s, :message, ""))
    |> string(Map.get(s, :hardware_id, ""))
    |> sequence(Map.get(s, :values, []), fn acc, {k, v} -> acc |> string(k) |> string(v) end)
  end
end
