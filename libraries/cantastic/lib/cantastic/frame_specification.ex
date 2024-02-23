defmodule Cantastic.FrameSpecification do
  alias Cantastic.SignalSpecification
  @behaviour Access

  defdelegate fetch(term, key), to: Map
  defdelegate get(term, key, default), to: Map
  defdelegate get_and_update(term, key, fun), to: Map
  defdelegate pop(term, key), to: Map

  defstruct [
    :id,
    :name,
    :network_name,
    :frequency,
    :validate_frequency,
    :signal_specifications,
    :frame_handlers
  ]

  def from_frame_specification(network_name, yaml_frame_specification) do
    yaml_signal_specifications   = yaml_frame_specification[:signals] || []
    {:ok, signal_specifications} = compute_signal_specifications(yaml_frame_specification.id, yaml_frame_specification.name, yaml_signal_specifications)
    frame_specification          = %Cantastic.FrameSpecification{
      id: yaml_frame_specification.id,
      name: yaml_frame_specification.name,
      network_name: network_name,
      frequency: yaml_frame_specification[:frequency],
      validate_frequency: yaml_frame_specification[:validate_frequency] || false,
      signal_specifications: signal_specifications,
      frame_handlers: []
    }
    {:ok, frame_specification}
  end

  defp compute_signal_specifications(frame_id, frame_name, yaml_signal_specifications) do
    computed = yaml_signal_specifications
    |> Enum.map(fn (yaml_signal_specification) ->
      {:ok, signal_specifications} = SignalSpecification.from_signal_specification(frame_id, frame_name, yaml_signal_specification)
      signal_specifications
    end)
    {:ok, computed}
  end
end
