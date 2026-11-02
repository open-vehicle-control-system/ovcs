defmodule VisionApiWeb.ParameterActionJSON do
  @moduledoc """
  A created save, discard or reset of the vision parameters as a JSON:API
  resource of `type`, listing the parameters it touched.
  """
  alias VisionApiWeb.JsonApi

  @doc "The action resource of `type` and `id`, with the ids of the `parameters` it touched."
  @spec show(%{type: String.t(), id: String.t(), parameters: [String.t()]}) :: map()
  def show(%{type: type, id: id, parameters: parameters}),
    do: %{data: JsonApi.resource(type, id, %{parameters: parameters})}
end
