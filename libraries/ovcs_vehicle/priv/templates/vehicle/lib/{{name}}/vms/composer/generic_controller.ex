defmodule <%= @module %>.Vms.Composer.GenericController do
  @moduledoc """
  Per-controller pin configuration.

  The key is the module process_name declared in `children/0`; the
  value is the pin map that the GenericController component will
  apply to the physical board at boot. Each pin is either `"enabled"`
  or `"disabled"`; add one entry per controller on the bus.
  """
  alias <%= @module %>.Vms

  def generic_controllers do
    %{
      Vms.ExampleController => %{
        "controller_id" => 0,
        "digital_pin0" => "disabled",
        "digital_pin1" => "disabled",
        "pwm_pin0" => "disabled",
        "analog_pin0" => "enabled"
      }
    }
  end
end
