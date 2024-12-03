defmodule VmsCore.Vehicles.OVCS1.Composer.Dashboard.GenericControllersPage do
  alias VmsCore.Vehicles.OVCS1

  def definition(order: order) do
    %{
      name: "Generic Controllers",
      icon: "PuzzlePieceIcon",
      order: order,
      blocks: %{
        "front-controller" => %{
          order: 0,
          name: "Front Controller Satus",
          type: "table",
          metrics: [
            %{name: "Alive?", module: OVCS1.FrontController, key: :is_alive},
            %{name: "Status", module: OVCS1.FrontController, key: :status},

            %{name: "Exp. Board1 Last Error", module: OVCS1.FrontController, key: :expansion_board1_last_error},

            %{name: "Requested Inverter Relay Enabled", module: OVCS1.FrontController, key: :requested_digital_pin3_enabled},
            %{name: "Received Inverter Relay Enabled", module: OVCS1.FrontController, key: :received_digital_pin3_enabled},

            %{name: "Requested Water Pump Relay Enabled", module: OVCS1.FrontController, key: :requested_digital_pin4_enabled},
            %{name: "Received Water Pump Relay Enabled", module: OVCS1.FrontController, key: :received_digital_pin4_enabled},

            %{name: "Requested I Booster Relay Enabled", module: OVCS1.FrontController, key: :requested_digital_pin5_enabled},
            %{name: "Received I Booster Relay Enabled", module: OVCS1.FrontController, key: :received_digital_pin5_enabled},

            %{name: "Requested Steering Column Relay Enabled", module: OVCS1.FrontController, key: :requested_digital_pin6_enabled},
            %{name: "Received Steering Column Relay Enabled", module: OVCS1.FrontController, key: :received_digital_pin6_enabled},
          ]
        },
        "controls-controller" => %{
          order: 1,
          name: "Controls Controller Satus",
          type: "table",
          metrics: [
            %{name: "Alive?", module: OVCS1.ControlsController, key: :is_alive},
            %{name: "Status", module: OVCS1.ControlsController, key: :status},
            %{name: "Steering Column PWM Enabled", module: OVCS1.ControlsController, key: :requested_external_pwm0_enabled},
            %{name: "Steering Column PWM Duty Cycle", module: OVCS1.ControlsController, key: :requested_external_pwm0_duty_cycle, unit: "%"},
            %{name: "Steering Column PWM frequency", module: OVCS1.ControlsController, key: :requested_external_pwm0_frequency, unit: "Hz"},
            %{name: "Requested Steering Columm Clockwise Dir.", module: OVCS1.ControlsController, key: :requested_digital_pin1_enabled},
            %{name: "Received Steering Columm Clockwise Dir.", module: OVCS1.ControlsController, key: :received_digital_pin1_enabled},
            %{name: "Received Raw Throttle A", module: OVCS1.ControlsController, key: :received_analog_pin0_value},
            %{name: "Received Raw Throttle B", module: OVCS1.ControlsController, key: :received_analog_pin1_value},
          ]
        },
        "rear_controller" => %{
          order: 2,
          name: "Rear Controller Satus",
          type: "table",
          metrics: [
            %{name: "Alive?", module: OVCS1.RearController, key: :is_alive},
            %{name: "Status", module: OVCS1.RearController, key: :status},

            %{name: "Exp. Board1 Last Error", module: OVCS1.RearController, key: :expansion_board1_last_error},
            %{name: "Exp. Board2 Last Error", module: OVCS1.RearController, key: :expansion_board2_last_error},

            %{name: "Requested Main Negative Relay Enabled", module: OVCS1.RearController, key: :requested_digital_pin3_enabled},
            %{name: "Received Main Negative Relay Enabled", module: OVCS1.RearController, key: :received_digital_pin3_enabled},

            %{name: "Requested Main Positive Relay Enabled", module: OVCS1.RearController, key: :requested_digital_pin4_enabled},
            %{name: "Received Main Positive Relay Enabled", module: OVCS1.RearController, key: :received_digital_pin4_enabled},

            %{name: "Requested Precharge Relay Enabled", module: OVCS1.RearController, key: :requested_digital_pin5_enabled},
            %{name: "Received Precharge Relay Enabled", module: OVCS1.RearController, key: :received_digital_pin5_enabled}
          ]
        }
      }
    }
  end
end
