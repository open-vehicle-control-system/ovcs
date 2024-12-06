defmodule VmsCore.Vehicles.OVCS1.Composer.Dashboard.GenericControllersPage do
  alias VmsCore.Vehicles.OVCS1
  alias VmsCore.Components.OVCS.GenericController

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
          rows: [
            %{type: :action, name: "Adopt", input_type: :button, module: GenericController, action: "adopt", extra_parameters: %{controller_name: OVCS1.FrontController}},

            %{type: :metric, name: "Alive?", module: OVCS1.FrontController, key: :is_alive},
            %{type: :metric, name: "Status", module: OVCS1.FrontController, key: :status},

            %{type: :metric, name: "Exp. Board1 Last Error", module: OVCS1.FrontController, key: :expansion_board1_last_error},

            %{type: :metric, name: "Requested Inverter Relay Enabled", module: OVCS1.FrontController, key: :requested_digital_pin3_enabled},
            %{type: :metric, name: "Received Inverter Relay Enabled", module: OVCS1.FrontController, key: :received_digital_pin3_enabled},

            %{type: :metric, name: "Requested Water Pump Relay Enabled", module: OVCS1.FrontController, key: :requested_digital_pin4_enabled},
            %{type: :metric, name: "Received Water Pump Relay Enabled", module: OVCS1.FrontController, key: :received_digital_pin4_enabled},

            %{type: :metric, name: "Requested I Booster Relay Enabled", module: OVCS1.FrontController, key: :requested_digital_pin5_enabled},
            %{type: :metric, name: "Received I Booster Relay Enabled", module: OVCS1.FrontController, key: :received_digital_pin5_enabled},

            %{type: :metric, name: "Requested Steering Column Relay Enabled", module: OVCS1.FrontController, key: :requested_digital_pin6_enabled},
            %{type: :metric, name: "Received Steering Column Relay Enabled", module: OVCS1.FrontController, key: :received_digital_pin6_enabled},
          ]
        },
        "controls-controller" => %{
          order: 1,
          name: "Controls Controller Satus",
          type: "table",
          rows: [
            %{type: :action, name: "Adopt", input_type: :button, module: GenericController, action: "adopt", extra_parameters: %{controller_name: OVCS1.ControlsController}},

            %{type: :metric, name: "Alive?", module: OVCS1.ControlsController, key: :is_alive},
            %{type: :metric, name: "Status", module: OVCS1.ControlsController, key: :status},

            %{type: :metric, name: "Steering Column PWM Enabled", module: OVCS1.ControlsController, key: :requested_external_pwm0_enabled},
            %{type: :metric, name: "Steering Column PWM Duty Cycle", module: OVCS1.ControlsController, key: :requested_external_pwm0_duty_cycle, unit: "%"},
            %{type: :metric, name: "Steering Column PWM frequency", module: OVCS1.ControlsController, key: :requested_external_pwm0_frequency, unit: "Hz"},

            %{type: :metric, name: "Requested Steering Columm Clockwise Dir.", module: OVCS1.ControlsController, key: :requested_digital_pin1_enabled},
            %{type: :metric, name: "Received Steering Columm Clockwise Dir.", module: OVCS1.ControlsController, key: :received_digital_pin1_enabled},

            %{type: :metric, name: "Received Raw Throttle A", module: OVCS1.ControlsController, key: :received_analog_pin0_value},
            %{type: :metric, name: "Received Raw Throttle B", module: OVCS1.ControlsController, key: :received_analog_pin1_value},
          ]
        },
        "rear_controller" => %{
          order: 2,
          name: "Rear Controller Satus",
          type: "table",
          rows: [
            %{type: :action, name: "Adopt", input_type: :button, module: GenericController, action: "adopt", extra_parameters: %{controller_name: OVCS1.RearController}},

            %{type: :metric, name: "Alive?", module: OVCS1.RearController, key: :is_alive},
            %{type: :metric, name: "Status", module: OVCS1.RearController, key: :status},

            %{type: :metric, name: "Exp. Board1 Last Error", module: OVCS1.RearController, key: :expansion_board1_last_error},
            %{type: :metric, name: "Exp. Board2 Last Error", module: OVCS1.RearController, key: :expansion_board2_last_error},

            %{type: :metric, name: "Requested Main Negative Relay Enabled", module: OVCS1.RearController, key: :requested_digital_pin3_enabled},
            %{type: :metric, name: "Received Main Negative Relay Enabled", module: OVCS1.RearController, key: :received_digital_pin3_enabled},

            %{type: :metric, name: "Requested Main Positive Relay Enabled", module: OVCS1.RearController, key: :requested_digital_pin4_enabled},
            %{type: :metric, name: "Received Main Positive Relay Enabled", module: OVCS1.RearController, key: :received_digital_pin4_enabled},

            %{type: :metric, name: "Requested Precharge Relay Enabled", module: OVCS1.RearController, key: :requested_digital_pin5_enabled},
            %{type: :metric, name: "Received Precharge Relay Enabled", module: OVCS1.RearController, key: :received_digital_pin5_enabled}
          ]
        }
      }
    }
  end
end
