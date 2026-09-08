defmodule OvcsMini.Vms.Composer.Dashboard.Blocks.ROSControlThrottleAndSteeringBlock do
  alias VmsCore.Components.OVCS.RosActuatorCommand

  def definition(order: order, full_width: full_width) do
    %{
      order: order,
      name: "ROS Steering & Throttle",
      type: "lineChart",
      full_width: full_width,
      serie_max_size: 300,
      y_axis: [
        %{
          min: -1,
          max: 1,
          label: "%",
          series: [
            %{
              name: "Requested Steering",
              metric: %{module: RosActuatorCommand.Steering, key: :requested_steering}
            },
            %{
              name: "Requested Throttle",
              metric: %{module: RosActuatorCommand.Throttle, key: :requested_throttle}
            }
          ]
        }
      ]
    }
  end
end
