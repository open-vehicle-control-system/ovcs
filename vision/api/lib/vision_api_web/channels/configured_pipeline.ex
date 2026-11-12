defmodule VisionApiWeb.ConfiguredPipeline do
  @moduledoc """
  The pipeline a channel topic names, among those of the running
  configuration: a client's topic is text, and only a configured
  pipeline's name is an atom already, so a topic can neither grow the
  atom table nor reach another module's process.
  """

  @doc """
  The pipeline named `name` whose output `{kind, pipeline}` is among
  `supervisor`'s outputs of the running configuration; `:error` for any
  other name, and on a unit that runs no pipeline.
  """
  @spec fetch(String.t(), :detections | :segmentation, module()) :: {:ok, atom()} | :error
  def fetch(name, kind, supervisor) do
    pipeline = String.to_existing_atom(name)
    if {kind, pipeline} in configured_outputs(supervisor), do: {:ok, pipeline}, else: :error
  rescue
    ArgumentError -> :error
  end

  defp configured_outputs(supervisor) do
    case VisionCore.Application.active_config() do
      nil -> []
      config -> for {output, _key} <- supervisor.outputs(config), do: output
    end
  end
end
