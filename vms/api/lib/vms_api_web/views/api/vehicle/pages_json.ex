defmodule VmsApiWeb.Api.Vehicle.PagesJSON do
  use VmsApiWeb, :view

  def render("index.json", %{pages: pages}) do
    %{
      data: render_many(pages, __MODULE__, "page.json", as: :page)
    }
  end

  def render("page.json", %{page: {page_id, page}}) do
    %{
      type: "page",
      id:    page_id,
      attributes: %{
        name: page.name
      }
    }
  end
end
