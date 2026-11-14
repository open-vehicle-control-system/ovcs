defmodule VisionApiWeb.ExporterOutput do
  @moduledoc "The name the API gives an exporter's output."

  @doc "An output's name: `stereo_pair`, `detections:<name>`, `camera_frame:<name>:<output>`."
  @spec name(VisionCore.Exporter.output()) :: String.t()
  def name({output, name}), do: "#{output}:#{name}"
  def name({output, name, camera_output}), do: "#{output}:#{name}:#{camera_output}"
  def name(output), do: Atom.to_string(output)
end
