defmodule VisionApiWeb.ParameterActionPresenter do
  @moduledoc """
  A created save, discard or reset of the vision parameters as a JSON:API
  resource of `type`, listing the parameters it touched.
  """
  alias VisionApiWeb.JsonApi

  @doc "The action resource of `type` and `id`, with the ids of the `parameters` it touched."
  @spec present(String.t(), String.t(), [String.t()]) :: map()
  def present(type, id, parameters), do: JsonApi.resource(type, id, %{parameters: parameters})
end
