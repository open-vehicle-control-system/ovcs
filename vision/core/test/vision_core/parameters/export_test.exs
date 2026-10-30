defmodule VisionCore.Parameters.ExportTest do
  use ExUnit.Case, async: true

  alias VisionCore.Parameters.Export

  test "renders config fields, component options and stage options as composer snippets" do
    rows = [
      {[:components, :stereo, :stages, :match, :p1], "stereo.match.p1", 10},
      {[:components, :stereo, :stages, :match, :p2], "stereo.match.p2", 70},
      {[:components, :stereo, :left, :exposure_us], "stereo.cameras.exposure_us", 8000},
      {[:components, :stereo, :align_correction], "stereo.alignment.correction", false},
      {[:preview, :max_hz], "preview.max_hz", 15},
      {nil, "stereo.left_camera.auto_exposure", false},
      {:not_running, "detection.min_score", 0.5}
    ]

    assert Export.render(rows) == """
           # In the composer's VisionCore.Config:
           preview: [max_hz: 15]

           # In the options of the stereo component ({:stereo, opts}):
           align_correction: false,
           left: [exposure_us: 8000],
           stages: VisionCore.Stereo.Pipeline.default_stages(match: [p1: 10, p2: 70])

           # Not settable in the composer:
           # stereo.left_camera.auto_exposure = false

           # Saved for parameters not running now:
           # detection.min_score = 0.5
           """
  end

  test "renders a config field named stages as plain options" do
    rows = [{[:stages, :match], "stages.match", 1}]

    assert Export.render(rows) == """
           # In the composer's VisionCore.Config:
           stages: [match: 1]
           """
  end

  test "renders nothing saved as a line saying so",
    do: assert(Export.render([]) == "# Nothing saved.\n")
end
