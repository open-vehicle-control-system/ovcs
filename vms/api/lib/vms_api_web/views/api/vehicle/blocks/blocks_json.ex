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
      subtype: block.type,
      fullWidth: block[:full_width]
    } |> Map.merge(render_one(block, __MODULE__, "#{block.type}_block_attributes.json", as: :block))
    %{
      type: "block",
      id:    block_id,
      attributes: attributes
    }
  end


  def render("table_block_attributes.json", %{block: block}) do
    %{
      rows: render_many(block.rows, __MODULE__, "row.json", as: :row)
    }
  end

  def render("lineChart_block_attributes.json", %{block: block}) do
    %{
      serieMaxSize: block.serie_max_size,
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
    %{
      name: serie.name,
      metric: render_one(serie.metric, __MODULE__, "metric.json", as: :metric)
    }
  end

  def render("row.json", %{row: row}) do
    case row.type do
      :metric -> render_one(row, __MODULE__, "metric.json", as: :metric)
      :action -> render_one(row, __MODULE__, "action.json", as: :action)
    end
  end

  def render("metric.json", %{metric: metric}) do
    %{

      name: metric[:name],
      type: :metric,
      module: metric.module,
      key: metric.key,
      unit: metric[:unit],
    }
  end

  def render("action.json", %{action: action}) do
    %{
      name: action.name,
      type: :action,
      inputType: action.input_type,
      inputName: action[:input_name] || action.name,
      module: action.module,
      action: action.action,
      extraParameters: action[:extra_parameters] || %{},
      statusMetricKey: action[:status_metric_key]
    }
  end
end
