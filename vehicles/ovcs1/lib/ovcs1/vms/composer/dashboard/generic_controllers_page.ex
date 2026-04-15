defmodule Ovcs1.Vms.Composer.Dashboard.GenericControllersPage do
  alias Ovcs1.Vms
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
            %{type: :action, name: "Adopt", input_type: :button, module: GenericController, action: "adopt", extra_parameters: %{controller_name: Vms.FrontController}},

            %{type: :metric, name: "Alive?", module: Vms.FrontController, key: :is_alive},
            %{type: :metric, name: "Status", module: Vms.FrontController, key: :status},

            %{type: :metric, name: "Exp. Board1 Last Error", module: Vms.FrontController, key: :expansion_board1_last_error},

            %{type: :metric, name: "Requested Fake Oil Sensor Relay Enabled", module: Vms.FrontController, key: :requested_digital_pin3_enabled},
            %{type: :metric, name: "Received Fake Oil Sensor Relay Enabled", module: Vms.FrontController, key: :received_digital_pin3_enabled},

            %{type: :metric, name: "Requested Water Pump Relay Enabled", module: Vms.FrontController, key: :requested_digital_pin4_enabled},
            %{type: :metric, name: "Received Water Pump Relay Enabled", module: Vms.FrontController, key: :received_digital_pin4_enabled},

            %{type: :metric, name: "Requested I Booster Relay Enabled", module: Vms.FrontController, key: :requested_digital_pin5_enabled},
            %{type: :metric, name: "Received I Booster Relay Enabled", module: Vms.FrontController, key: :received_digital_pin5_enabled},

            %{type: :metric, name: "Requested Steering Column Relay Enabled", module: Vms.FrontController, key: :requested_digital_pin6_enabled},
            %{type: :metric, name: "Received Steering Column Relay Enabled", module: Vms.FrontController, key: :received_digital_pin6_enabled},
          ]
        },
        "controls-controller" => %{
          order: 1,
          name: "Controls Controller Satus",
          type: "table",
          rows: [
            %{type: :action, name: "Adopt", input_type: :button, module: GenericController, action: "adopt", extra_parameters: %{controller_name: Vms.ControlsController}},

            %{type: :metric, name: "Alive?", module: Vms.ControlsController, key: :is_alive},
            %{type: :metric, name: "Status", module: Vms.ControlsController, key: :status},

            %{type: :metric, name: "Steering Column PWM Enabled", module: Vms.ControlsController, key: :requested_external_pwm0_enabled},
            %{type: :metric, name: "Steering Column PWM Duty Cycle", module: Vms.ControlsController, key: :requested_external_pwm0_duty_cycle, unit: "%"},
            %{type: :metric, name: "Steering Column PWM frequency", module: Vms.ControlsController, key: :requested_external_pwm0_frequency, unit: "Hz"},

            %{type: :metric, name: "Requested Steering Columm Clockwise Dir.", module: Vms.ControlsController, key: :requested_digital_pin1_enabled},
            %{type: :metric, name: "Received Steering Columm Clockwise Dir.", module: Vms.ControlsController, key: :received_digital_pin1_enabled},

            %{type: :metric, name: "Received Raw Throttle A", module: Vms.ControlsController, key: :received_analog_pin0_value},
            %{type: :metric, name: "Received Raw Throttle B", module: Vms.ControlsController, key: :received_analog_pin1_value},
          ]
        },
        "rear_controller" => %{
          order: 2,
          name: "Rear Controller Satus",
          type: "table",
          rows: [
            %{type: :action, name: "Adopt", input_type: :button, module: GenericController, action: "adopt", extra_parameters: %{controller_name: Vms.RearController}},

            %{type: :metric, name: "Alive?", module: Vms.RearController, key: :is_alive},
            %{type: :metric, name: "Status", module: Vms.RearController, key: :status},

            %{type: :metric, name: "Exp. Board1 Last Error", module: Vms.RearController, key: :expansion_board1_last_error},
            %{type: :metric, name: "Exp. Board2 Last Error", module: Vms.RearController, key: :expansion_board2_last_error},

            %{type: :metric, name: "Requested Main Negative Relay Enabled", module: Vms.RearController, key: :requested_digital_pin3_enabled},
            %{type: :metric, name: "Received Main Negative Relay Enabled", module: Vms.RearController, key: :received_digital_pin3_enabled},

            %{type: :metric, name: "Requested Main Positive Relay Enabled", module: Vms.RearController, key: :requested_digital_pin4_enabled},
            %{type: :metric, name: "Received Main Positive Relay Enabled", module: Vms.RearController, key: :received_digital_pin4_enabled},

            %{type: :metric, name: "Requested Precharge Relay Enabled", module: Vms.RearController, key: :requested_digital_pin5_enabled},
            %{type: :metric, name: "Received Precharge Relay Enabled", module: Vms.RearController, key: :received_digital_pin5_enabled},

            %{type: :metric, name: "Requested BMS Ready Relay Enabled", module: Vms.RearController, key: :requested_digital_pin6_enabled},
            %{type: :metric, name: "Received BMS Ready Relay Enabled", module: Vms.RearController, key: :received_digital_pin6_enabled},

            %{type: :metric, name: "Requested Inverter Relay Enabled", module: Vms.RearController, key: :requested_digital_pin7_enabled},
            %{type: :metric, name: "Received Inverter Relay Enabled", module: Vms.RearController, key: :received_digital_pin7_enabled}
          ]
        }
      }
    }
  end
end
