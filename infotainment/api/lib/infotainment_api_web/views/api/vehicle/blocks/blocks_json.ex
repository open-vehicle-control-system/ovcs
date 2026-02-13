defmodule InfotainmentApiWeb.Api.Vehicle.Page.BlocksJSON do
  use InfotainmentApiWeb, :view

  def render("index.json", %{blocks: blocks}) do
    %{
      data:
        render_many(
          blocks
          |> Enum.sort(fn {_, %{order: order1}}, {_, %{order: order2}} -> order1 <= order2 end),
          __MODULE__,
          "block.json",
          as: :block
        )
    }
  end

  def render("block.json", %{block: {block_id, block}}) do
    %{
      type: "block",
      id: block_id,
      attributes: %{
        name: block.name,
        subtype: block.type,
        column: block[:column] || 0,
        row: block[:row] || 0,
        columns: block.columns,
        rows: block.rows,
        metrics: render_metrics(block[:metrics]),
        actions: render_actions(block[:actions]),
        config: block[:config]
      }
    }
  end

  defp render_metrics(nil), do: []

  defp render_metrics(metrics) do
    Enum.map(metrics, fn metric ->
      %{
        module: metric.module,
        key: metric.key,
        label: metric[:label]
      }
    end)
  end

  defp render_actions(nil), do: []

  defp render_actions(actions) do
    Enum.map(actions, fn action ->
      %{
        module: action.module,
        action: action.action
      }
    end)
  end
end
