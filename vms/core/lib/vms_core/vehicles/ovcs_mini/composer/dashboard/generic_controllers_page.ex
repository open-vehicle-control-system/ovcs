defmodule VmsCore.Vehicles.OVCSMini.Composer.Dashboard.GenericControllersPage do
  alias VmsCore.Vehicles.OVCSMini
  alias VmsCore.Components.OVCS.GenericController

  def definition(order: order) do
    %{
      name: "Generic Controllers",
      icon: "PuzzlePieceIcon",
      order: order,
      blocks: %{
        "main-controller" => %{
          order: 1,
          name: "Main Controller Satus",
          type: "table",
          rows: [
            %{type: :action, name: "Adopt", input_type: :button, module: GenericController, action: "adopt", extra_parameters: %{controller_name: OVCSMini.MainController}},

            %{type: :metric, name: "Alive?", module: OVCSMini.MainController, key: :is_alive},
            %{type: :metric, name: "Status", module: OVCSMini.MainController, key: :status},

            %{type: :metric, name: "Steering PWM Enabled", module: OVCSMini.MainController, key: :requested_external_pwm0_enabled},
            %{type: :metric, name: "Steering PWM Duty Cycle", module: OVCSMini.MainController, key: :requested_external_pwm0_duty_cycle, unit: "%"},
            %{type: :metric, name: "Steering PWM frequency", module: OVCSMini.MainController, key: :requested_external_pwm0_frequency, unit: "Hz"},

            %{type: :metric, name: "Throttle PWM Enabled", module: OVCSMini.MainController, key: :requested_external_pwm1_enabled},
            %{type: :metric, name: "Throttle PWM Duty Cycle", module: OVCSMini.MainController, key: :requested_external_pwm1_duty_cycle, unit: "%"},
            %{type: :metric, name: "Throttle PWM frequency", module: OVCSMini.MainController, key: :requested_external_pwm1_frequency, unit: "Hz"},
          ]
        }
      }
    }
  end
end
