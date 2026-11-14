defmodule SimulatorCore.SimulatedComponents.OVCS.GenericController.DigitalPinRequestTest do
  use ExUnit.Case, async: true

  import SimulatorCore.CanFrames, only: [signals: 1]

  alias SimulatorCore.SimulatedComponents.OVCS.GenericController.DigitalPinRequest

  test "the request frame is named after its controller" do
    assert DigitalPinRequest.frame_name("rear_controller") ==
             "rear_controller_digital_pin_request"
  end

  describe "enabled?/2" do
    test "is true for a pin the request enables" do
      request = signals(%{"digital_pin4_enabled" => false, "digital_pin5_enabled" => true})

      assert DigitalPinRequest.enabled?(request, 5)
    end

    test "is false for a pin the request disables" do
      request = signals(%{"digital_pin4_enabled" => false, "digital_pin5_enabled" => true})

      refute DigitalPinRequest.enabled?(request, 4)
    end

    test "is false for a pin the request does not carry" do
      refute DigitalPinRequest.enabled?(signals(%{"digital_pin5_enabled" => true}), 6)
    end
  end

  test "requested/1 is every pin the request carries, by signal name" do
    request =
      signals(%{"digital_pin0_enabled" => true, "digital_pin18_enabled" => false, "filler0" => 0})

    assert DigitalPinRequest.requested(request) ==
             %{"digital_pin0_enabled" => true, "digital_pin18_enabled" => false}
  end
end
