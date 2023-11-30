defmodule OvcsInfotainmentBackend.Can.CompiledSignalSpec do

  defstruct [
    :name,
    :kind,
    :frame_id,
    :value_start,
    :value_length,
    :endianness,
    :mapping,
    :unit,
    :origin,
    :scale,
    :offset,
    :decimals
  ]

  def from_signal_spec(name, signal_spec) do
    compiled_signal_spec = %OvcsInfotainmentBackend.Can.CompiledSignalSpec{
      name: name,
      frame_id: convert_hex_to_integer(signal_spec["frameId"]),
      kind: signal_spec["kind"] || "integer",
      value_start: signal_spec["valueStart"] || 0,
      value_length: signal_spec["valueLength"] || 1,
      endianness: signal_spec["endianness"] || "little",
      mapping: compile_mapping(signal_spec["mapping"]),
      unit: signal_spec["unit"],
      origin: signal_spec["origin"],
      scale: signal_spec["scale"] || 1,
      offset: signal_spec["offset"] || 0,
      decimals: signal_spec["decimals"] || 0,
    }
    {:ok, compiled_signal_spec}
  end

  defp compile_mapping(nil), do: nil
  defp compile_mapping(mapping) do
    mapping |> Map.keys() |> Enum.reduce(%{}, fn(hex_key, compiled_mapping) ->
      key = convert_hex_to_integer(hex_key)
      compiled_mapping |> Map.put(key, mapping[hex_key])
    end)
  end

  defp convert_hex_to_integer(hex) do
    {int, _} = Integer.parse(hex, 16)
    int
  end
end
