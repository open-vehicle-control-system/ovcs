defmodule VmsApiWeb.Api.Vehicle.Page.BlocksJSON do
  use VmsApiWeb, :view

  def render("index.json", %{blocks: blocks}) do
    %{
      data: render_many(blocks |> Enum.sort(fn({_, %{order: order1}}, {_, %{order: order2}}) -> order1 <= order2 end), __MODULE__, "block.json", as: :block)
    }
  end

  def render("block.json", %{block: {block_id, block}}) do
    attributes =  %{
      name: block.name,
      subtype: block.type
    } |> Map.merge(render_one(block, __MODULE__, "#{block.type}_block_attributes.json", as: :block))
    %{
      type: "block",
      id:    block_id,
      attributes: attributes
    }
  end

  def render("table_block_attributes.json", %{block: block}) do
    %{
      metrics: render_many(block.metrics, __MODULE__, "metric.json", as: :metric)
    }
  end

  def render("lineChart_block_attributes.json", %{block: block}) do
    %{
      refreshInterval: block.refresh_interval,
      yAxis: render_many(block.y_axis, __MODULE__, "y_axis.json", as: :y_axis)
    }
  end

  def render("y_axis.json", %{y_axis: y_axis}) do
    %{
      min: y_axis.min,
      max: y_axis.max,
      label: y_axis.label,
      series: y_axis.series
    }
  end

  def render("serie.json", %{serie: serie}) do
    %{name: serie.name, metric: render_one(serie.metric, __MODULE__, "metric.json", as: :metric)}
  end

  def render("metric.json", %{metric: metric}) do
    %{module: metric.module, name: metric.name, unit: metric.unit}
  end
end
