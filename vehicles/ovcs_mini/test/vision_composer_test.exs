defmodule OvcsMini.VisionComposerTest do
  use ExUnit.Case, async: true

  test "the stereo unit matches at most 20 pairs a second, a value its vision parameter takes" do
    %VisionCore.Config{components: components} = OvcsMini.Vision.Composer.config(:target)
    stereo = Keyword.fetch!(components, :stereo)

    assert %{max_hz: 20.0, pair_tolerance_ms: 5} =
             VisionCore.Settings.init!(VisionCore.Stereo.Pairer.setting_specs(), stereo)

    assert {:ok, _cameras} =
             VisionCore.Stereo.Supervisor.camera_options(OvcsMini.Vision.Composer.config(:target))
  end
end
