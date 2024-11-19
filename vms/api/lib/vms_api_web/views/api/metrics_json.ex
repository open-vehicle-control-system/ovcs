defmodule VmsApiWeb.Api.MetricsJSON do
  use VmsApiWeb, :view

  def render("metrics.json", %{metrics: metrics}) do
    %{
      data: metrics
    }
  end
end
