defmodule VmsApiWeb.Api.MetricsJSON do
  use VmsApiWeb, :view

  def render("metrics.json", %{metrics: metrics} = assigns) do
    %{
      data: metrics,
      units: Map.get(assigns, :units, %{})
    }
  end
end
