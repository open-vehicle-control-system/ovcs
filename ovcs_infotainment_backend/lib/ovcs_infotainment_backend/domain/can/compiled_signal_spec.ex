defmodule OvcsInfotainmentBackend.Can.CompiledSignalSpec do

  defstruct [
    :name,
    :kind,
    :frame_id,
    :start_byte,
    :byte_number,
    :endianness,
    :mapping,
    :unit,
    :emitter
  ]

  def from_signal_spec(name, signal_spec) do
    compiled_signal_spec = %OvcsInfotainmentBackend.Can.CompiledSignalSpec{
      name: name,
      frame_id: convert_hex_to_integer(signal_spec["frameId"]),
      kind: signal_spec["kind"] || "integer",
      start_byte: signal_spec["startByte"] || 0,
      byte_number: signal_spec["byteNumber"] || 1,
      endianness: signal_spec["endianness"] || "little",
      mapping: compile_mapping(signal_spec["mapping"]),
      unit: signal_spec["unit"],
      emitter: signal_spec["emitter"]
    }
    {:ok, compiled_signal_spec}
  end

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
