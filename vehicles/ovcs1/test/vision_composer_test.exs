defmodule Ovcs1.VisionComposerTest do
  use ExUnit.Case, async: true

  test "OVCS1's vision unit targets the VENTUNO Q" do
    assert Ovcs1.vision_target() == :arduino_ventuno_q
    assert Ovcs1.vision() == Ovcs1.Vision.Composer
    assert %VisionCore.Config{} = Ovcs1.Vision.Composer.config(:host)
    assert %VisionCore.Config{} = Ovcs1.Vision.Composer.config(:target)
  end
end
