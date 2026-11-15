defmodule VisionApiWeb.Exporter do
  @moduledoc "How the API describes an exporter, for the views and the controller that list them."

  @doc "The API's own entry among the exporters: its `id` and `name`."
  @spec api_entry() :: %{id: String.t(), name: String.t()}
  def api_entry, do: %{id: "api", name: "API"}

  @doc "An exporter's status: its `level`, as a string, and its `detail`."
  @spec status(VisionCore.Exporter.status()) :: %{level: String.t(), detail: String.t()}
  def status({level, detail}), do: %{level: Atom.to_string(level), detail: detail}

  @doc "An output's name: `stereo_pair`, `detections:<name>`, `camera_frame:<name>:<output>`."
  @spec output_name(VisionCore.Exporter.output()) :: String.t()
  def output_name({output, name}), do: "#{output}:#{name}"
  def output_name({output, name, camera_output}), do: "#{output}:#{name}:#{camera_output}"
  def output_name(output), do: Atom.to_string(output)
end
