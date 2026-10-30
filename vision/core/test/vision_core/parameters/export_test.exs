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
      {nil, "stereo.left_camera.auto_exposure", false}
    ]

    assert Export.render(rows) == """
           # In the composer's VisionCore.Config:
           preview: [max_hz: 15]

           # In the options of the {:stereo, opts} component:
           align_correction: false,
           left: [exposure_us: 8000],
           stages: Pipeline.default_stages(match: [p1: 10, p2: 70])

           # Not settable in the composer:
           # stereo.left_camera.auto_exposure = false
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
