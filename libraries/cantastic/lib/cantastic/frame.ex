defmodule Cantastic.Frame do
  alias Cantastic.{Util, CompiledSignalSpec}

  defstruct [:id, :data_length, :raw_data, :network_name]

  def build(id: id, network_name: network_name, raw_data: raw_data) do
    %Cantastic.Frame{
      id: id,
      network_name: network_name,
      raw_data: raw_data,
      data_length: byte_size(raw_data)
    }
  end

  def build_from_compiled_spec(compiled_frame_spec, parameters) do
    raw_data = build_raw_data_from_compiled_spec(compiled_frame_spec, parameters)
    Cantastic.Frame.build(id: compiled_frame_spec.id, network_name: compiled_frame_spec.network_name, raw_data: raw_data)
  end

  def build_raw_data_from_compiled_spec(compiled_frame_spec, parameters) do
    compiled_frame_spec.compiled_signal_specs
    |> Enum.reduce(<<>>, fn (compiled_signal_spec, raw_data) ->
      value = (parameters || %{})[compiled_signal_spec.name]
      raw_signal = CompiledSignalSpec.instantiate_raw(raw_data, compiled_signal_spec, value)
      Kernel.<>(raw_data, raw_signal)
    end)
  end

  def to_string(frame) do
    "[Frame] #{frame.network_name} - #{format_id(frame)}  [#{frame.data_length}]  #{format_data(frame)}"
  end

  def format_id(frame) do
    frame.id |> Util.integer_to_hex()
  end

  def format_data(frame) do
    frame.raw_data
    |> Util.bin_to_hex()
    |> String.split("", trim: true)
    |> Enum.chunk_every(2)
    |> Enum.join(" ")
  end

  def to_bin(frame) do
    padding = 8 - frame.data_length
    << frame.id::little-integer-size(16),
      0::2 * 8,
      frame.data_length,
      0::3 * 8
    >> <>
    frame.raw_data <>
    <<0::padding * 8>>
  end
end
