defmodule InfotainmentApiWeb.Api.Vehicle.PagesJSON do
  use InfotainmentApiWeb, :view

  def render("index.json", %{pages: pages}) do
    %{
      data: render_many(
        pages |> Enum.sort(fn({_, %{order: order1}}, {_, %{order: order2}}) -> order1 <= order2 end),
        __MODULE__,
        "page.json",
        as: :page
      )
    }
  end

  def render("page.json", %{page: {page_id, page}}) do
    %{
      type: "page",
      id:    page_id,
      attributes: %{
        name: page.name,
        icon: page[:icon],
        backgroundImage: page[:background_image]
      }
    }
  end
end
