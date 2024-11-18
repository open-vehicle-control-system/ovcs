defmodule VmsApiWeb.Api.Vehicle.Page.BlocksJSON do
  use VmsApiWeb, :view

  def render("index.json", %{blocks: blocks}) do
    %{
      data: render_many(blocks |> Enum.sort(fn({_, %{order: order1}}, {_, %{order: order2}}) -> order1 <= order2 end), __MODULE__, "block.json", as: :block)
    }
  end

  def render("block.json", %{block: {block_id, block}}) do
    %{
      type: "block",
      id:    block_id,
      attributes: %{
        name: block.name
      }
    }
  end
end
