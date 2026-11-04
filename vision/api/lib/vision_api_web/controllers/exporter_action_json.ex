defmodule VisionApiWeb.ExporterActionJSON do
  @moduledoc """
  The JSON result of an exporter's action as a JSON:API resource of
  `type`, whose attributes are the result.
  """
  alias VisionApiWeb.JsonApi

  @doc "The resource of `type` and `id`, with the action's `result` for attributes."
  @spec show(%{type: String.t(), id: String.t(), result: map()}) :: map()
  def show(%{type: type, id: id, result: result}),
    do: %{data: JsonApi.resource(type, id, result)}
end
