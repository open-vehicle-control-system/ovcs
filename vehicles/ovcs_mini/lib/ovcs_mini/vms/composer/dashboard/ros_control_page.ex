defmodule OvcsMini.Vms.Composer.Dashboard.ROSControlPage do
  alias VmsCore.Components.OVCS.RosActuatorCommand
  alias OvcsMini.Vms
  alias OvcsMini.Vms.Composer.Dashboard.Blocks.ThrottleInputCurveBlock
  alias OvcsMini.Vms.Composer.Dashboard.Blocks.ROSControlThrottleAndSteeringBlock

  def definition(order: order) do
    %{
      name: "ROS Control",
      icon: "CpuChipIcon",
      order: order,
      blocks: %{
        "status" => %{
          order: 0,
          name: "Status",
          type: "table",
          rows: [
            %{
              type: :metric,
              name: "Requested Steering",
              module: RosActuatorCommand.Steering,
              key: :requested_steering
            },
            %{
              type: :metric,
              name: "Requested Throttle",
              module: RosActuatorCommand.Throttle,
              key: :requested_throttle
            }
          ]
        },
        "throttle-input-curve-settings" =>
          ThrottleInputCurveBlock.settings(order: 2, curve: Vms.TeleopThrottleInputCurve),
        "throttle-input-curve" =>
          ThrottleInputCurveBlock.chart(order: 3, curve: Vms.TeleopThrottleInputCurve),
        "steering-and-throttle" =>
          ROSControlThrottleAndSteeringBlock.definition(order: 1, full_width: false)
      }
    }
  end
end
