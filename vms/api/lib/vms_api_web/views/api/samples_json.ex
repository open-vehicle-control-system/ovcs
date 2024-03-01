defmodule VmsApiWeb.Api.SamplesJSON do
  use VmsApiWeb, :view

  def render("index.json", %{samples: samples, other_var: other_var}) do
    render_many(samples, __MODULE__, "sample.json", as: :sample, other_var: other_var)
  end

  def render("show.json", %{sample: sample, other_var: other_var}) do
    %{
      data: render_one(sample, __MODULE__, "sample.json", as: :sample, other_var: other_var)
    }
  end

  def render("sample.json", %{sample: sample, other_var: other_var}) do
    %{
      type: "sample",
      id:    sample.id,
      attributes: %{
        name: sample.name
      },
      meta: %{
        other_var: other_var
      }
    }
  end
end
