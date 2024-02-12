defmodule Cantastic.CompiledFrameSpec do
  alias Cantastic.{Util, CompiledSignalSpec}

  defstruct [
    :id,
    :name,
    :network_name,
    :frequency,
    :validate_frequency,
    :compiled_signal_specs
  ]

  def from_frame_spec(network_name, name, frame_spec) do
    frame_id            = frame_spec["id"] |> Util.hex_to_integer
    signal_specs        = frame_spec["signals"] || []
    compiled_frame_spec = %Cantastic.CompiledFrameSpec{
      id: frame_id,
      name: name,
      network_name: network_name,
      frequency: frame_spec["frequency"],
      validate_frequency: frame_spec["validateFrequency"] || false,
      compiled_signal_specs: compile_signal_specs(frame_id, name, signal_specs)
    }
    {:ok, compiled_frame_spec}
  end

  defp compile_signal_specs(frame_id, frame_name, signal_specs) do
      signal_specs
      |> Enum.map(fn (signal_spec) ->
        {:ok, compiled_signal_spec} = CompiledSignalSpec.from_signal_spec(frame_id, frame_name, signal_spec)
        compiled_signal_spec
      end)
  end
end
