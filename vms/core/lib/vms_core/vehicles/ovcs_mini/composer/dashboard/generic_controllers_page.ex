defmodule VmsCore.Vehicles.OVCSMini.Composer.Dashboard.GenericControllersPage do
  alias VmsCore.Vehicles.OVCSMini

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
          metrics: [
            %{name: "Alive?", module: OVCSMini.MainController, key: :is_alive},

            %{name: "Steering PWM Enabled", module: OVCSMini.MainController, key: :requested_external_pwm0_enabled},
            %{name: "Steering PWM Duty Cycle", module: OVCSMini.MainController, key: :requested_external_pwm0_duty_cycle, unit: "%"},
            %{name: "Steering PWM frequency", module: OVCSMini.MainController, key: :requested_external_pwm0_frequency, unit: "Hz"},

            %{name: "Throttle PWM Enabled", module: OVCSMini.MainController, key: :requested_external_pwm1_enabled},
            %{name: "Throttle PWM Duty Cycle", module: OVCSMini.MainController, key: :requested_external_pwm1_duty_cycle, unit: "%"},
            %{name: "Throttle PWM frequency", module: OVCSMini.MainController, key: :requested_external_pwm1_frequency, unit: "Hz"},
          ]
        }
      }
    }
  end
end
