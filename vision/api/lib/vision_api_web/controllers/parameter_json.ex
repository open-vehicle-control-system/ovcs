defmodule VisionApiWeb.ParameterJSON do
  @moduledoc "Each `VisionCore.Parameters.Parameter` as a `parameters` JSON:API resource (`VisionApiWeb.ParameterResource`)."
  alias VisionApiWeb.ParameterResource
  alias VisionCore.Parameters.{Group, Parameter}

  @doc "The parameters of `groups`, in order, with how many are unsaved in `meta`."
  @spec index(%{groups: [Group.t()]}) :: map()
  def index(%{groups: groups}) do
    %{
      data:
        for(
          group <- groups,
          parameter <- group.parameters,
          do: ParameterResource.object(parameter)
        ),
      meta: ParameterResource.meta(groups)
    }
  end

  @doc "One `parameter`."
  @spec show(%{parameter: Parameter.t()}) :: map()
  def show(%{parameter: parameter}), do: %{data: ParameterResource.object(parameter)}
end
