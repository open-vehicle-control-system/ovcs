defmodule VisionApiWeb.ExporterJSON do
  @moduledoc """
  The unit's exporters as `exporters` JSON:API resources, each identified
  by its id: `name`, `module`, `status` (`level`, `ok`, `warning` or
  `off`, and `detail`) and `outputs`, each output's `name`
  (`stereo_pair`, `camera_frame:left`, `camera_frame:right`,
  `camera_frame:<name>` for the camera `<name>`'s frames, `detections` for
  the default detection pipeline's, or `detections:<name>` for the pipeline
  `<name>`'s) and `maxHz`, the most values it takes a second, `null` when
  unbounded, and `actions`, each with a `name`, a `label` and a
  `description`.
  """
  alias VisionApiWeb.JsonApi

  @doc "The `exporters`, as `VisionCore.Exporters.list/1` lists them."
  @spec index(%{exporters: [VisionCore.Exporters.entry()]}) :: map()
  def index(%{exporters: exporters}), do: %{data: Enum.map(exporters, &data/1)}

  defp data(exporter) do
    JsonApi.resource("exporters", exporter.id, %{
      name: exporter.name,
      module: inspect(exporter.module),
      status: status(exporter.status),
      outputs: Enum.map(exporter.outputs, &output/1),
      actions: Enum.map(exporter.actions, &action/1)
    })
  end

  @doc "An exporter's status: its `level`, as a string, and its `detail`."
  @spec status(VisionCore.Exporter.status()) :: %{level: String.t(), detail: String.t()}
  def status({level, detail}), do: %{level: Atom.to_string(level), detail: detail}

  defp action(%{name: name, label: label, description: description}),
    do: %{name: Atom.to_string(name), label: label, description: description}

  defp output(%{output: output, max_hz: max_hz}), do: %{name: output_name(output), maxHz: max_hz}

  defp output_name({output, name}), do: "#{output}:#{name}"
  defp output_name(output), do: Atom.to_string(output)
end
