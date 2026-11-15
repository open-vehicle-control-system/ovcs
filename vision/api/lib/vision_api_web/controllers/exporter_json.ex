defmodule VisionApiWeb.ExporterJSON do
  @moduledoc """
  The unit's exporters as `exporters` JSON:API resources, each identified
  by its id: `name`, `module` and `outputs`, each output's `name`
  (`stereo_pair`, `stereo_frame:left`, `stereo_frame:right`,
  `camera_frame:<name>` for the camera `<name>`'s frames,
  `camera_frame:<name>:<output>` for those of its output `<output>`,
  `detections:<name>` for the detection pipeline `<name>`'s,
  `detections:detection` for a detector without a name, or
  `segmentation:<name>` for the segmentation
  pipeline `<name>`'s) and `maxHz`, the most values it takes a second,
  `null` when unbounded, and for the API's outputs `source`, the
  preview stream it is shown on, or the pipeline's results are drawn on:
  `<prefix>/left`, `<prefix>/right` or `<prefix>/depth` for the stereo
  unit's, under its prefix, or a camera's name; and `actions`, each with
  a `name`, a `label` and a `description`.
  """
  alias VisionApiWeb.{Exporter, JsonApi}

  @doc "The `exporters`, as `VisionCore.Exporters.describe/0` describes them."
  @spec index(%{exporters: [VisionCore.Exporters.description()]}) :: map()
  def index(%{exporters: exporters}), do: %{data: Enum.map(exporters, &data/1)}

  defp data(exporter) do
    JsonApi.resource("exporters", exporter.id, %{
      name: exporter.name,
      module: inspect(exporter.module),
      outputs: Enum.map(exporter.outputs, &output/1),
      actions: Enum.map(exporter.actions, &action/1)
    })
  end

  defp action(%{name: name, label: label, description: description}),
    do: %{name: Atom.to_string(name), label: label, description: description}

  defp output(%{output: output, max_hz: max_hz} = entry),
    do:
      Map.merge(
        %{name: Exporter.output_name(output), maxHz: max_hz},
        Map.take(entry, [:source])
      )
end
