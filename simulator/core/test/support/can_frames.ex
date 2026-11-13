defmodule SimulatorCore.CanFrames do
  @moduledoc """
  Runs a simulated component's frames through the frame definitions in
  `ovcs_can`, as Cantastic emits them and the VMS receives them.
  """
  alias Cantastic.{Frame, FrameSpecification, Signal}

  @doc "`values` as decoded signals keyed by signal name, as `handle_frame/4` receives them."
  def signals(values),
    do: Map.new(values, fn {name, value} -> {name, %Signal{name: name, value: value}} end)

  @doc """
  The values the VMS decodes from `values`, emitted with the definition
  at `emitted_path` and received with the one at `received_path`, both
  under `ovcs_can`'s `priv/`. Raises if Cantastic refuses to emit with
  the emitted definition.
  """
  def read_back(values, emitted_path, received_path \\ nil) do
    emitted = specification(emitted_path, :emit)
    {:ok, raw} = Frame.build_raw(emitted, values)
    data = binary_part(raw, 8, emitted.byte_number)

    frame = %Frame{
      id: emitted.id,
      network_name: :simulated,
      raw_data: data,
      byte_number: byte_size(data)
    }

    {:ok, frame} = Frame.interpret(frame, specification(received_path || emitted_path, :receive))
    Map.new(frame.signals, fn {name, %Signal{value: value}} -> {name, value} end)
  end

  defp specification(path, direction) do
    {:ok, yaml} =
      :ovcs_can
      |> :code.priv_dir()
      |> Path.join(path)
      |> YamlElixir.read_from_file(atoms: true, merge_anchors: true)

    yaml = yaml |> Jason.encode!() |> Jason.decode!(keys: :atoms)
    {:ok, specification} = FrameSpecification.from_yaml(:simulated, yaml, direction)
    specification
  catch
    :throw, message -> raise ArgumentError, "#{path} as #{direction}: #{message}"
  end
end
