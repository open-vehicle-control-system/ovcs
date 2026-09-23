defmodule OvcsMini.Vms.Composer.Dashboard.Blocks.ThrottleInputCurveBlock do
  @moduledoc """
  One `OVCS.InputCurve` instance: its input against its shaped output
  over time, and its settings.
  """

  def chart(order: order, curve: curve) do
    %{
      order: order,
      name: "Throttle Input Curve",
      type: "lineChart",
      full_width: false,
      serie_max_size: 300,
      y_axis: [
        %{
          min: -1,
          max: 1,
          label: "request",
          series: [
            %{name: "Input", metric: %{module: curve, key: :input_throttle}},
            %{name: "Shaped", metric: %{module: curve, key: :requested_throttle}}
          ]
        }
      ]
    }
  end

  def settings(order: order, curve: curve) do
    %{
      order: order,
      name: "Throttle Input Curve",
      type: "table",
      rows: [
        %{type: :metric, name: "Input", module: curve, key: :input_throttle},
        %{type: :metric, name: "Shaped", module: curve, key: :requested_throttle},
        %{type: :metric, name: "Dead zone", module: curve, key: :deadzone},
        %{type: :metric, name: "Expo", module: curve, key: :expo}
      ]
    }
  end
end
