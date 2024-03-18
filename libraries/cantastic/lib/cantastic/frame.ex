defmodule Cantastic.Frame do
  alias Cantastic.{Util, Signal}

  defstruct [
    :id,
    :name,
    :data_length,
    :raw_data,
    :network_name,
    created_at: DateTime.utc_now(),
    signals: %{},
  ]

  def build_raw(frame_specification, parameters) do
    {:ok, raw_data, data_length} = build_raw_data(frame_specification, parameters)
    frame = %__MODULE__{
      id: frame_specification.id,
      network_name: frame_specification.network_name,
      raw_data: raw_data,
      data_length: data_length
    }
    {:ok, to_raw(frame)}
  end

  defp build_raw_data(frame_specification, parameters) do
    raw_data = frame_specification.signal_specifications
    |> Enum.reduce(<<>>, fn (signal_specification, raw_data) ->
      value      = (parameters || %{})[signal_specification.name]
      raw_signal = Signal.build_raw(raw_data, signal_specification, value)
      <<raw_data::bitstring, raw_signal::bitstring>>
    end)
    data_length = byte_size(raw_data)
    {:ok, raw_data, data_length}
  end

  def interpret(frame, frame_specification) do
    signals = frame_specification.signal_specifications |> Enum.reduce(%{}, fn(signal_specification, acc) ->
      {:ok, signal} =  Signal.interpret(frame, signal_specification)
      put_in(acc, [signal.name], signal)
    end)
    frame = %{frame | name: frame_specification.name, signals: signals}
    {:ok, frame}
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

  defp to_raw(frame) do
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
