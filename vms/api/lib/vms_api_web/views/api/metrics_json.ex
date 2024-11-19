defmodule VmsApiWeb.Api.MetricsJSON do
  use VmsApiWeb, :view

  def render("metrics.json", %{metrics: metrics}) do
    %{
      type: "metrics",
      id:    "metrics",
      attributes: metrics
    }
  end
end
