defmodule VisionApiWeb.StatusJSONTest do
  use ExUnit.Case, async: true

  alias VisionApiWeb.StatusJSON

  test "gives the snapshot's fields camelCase keys and states as strings, each exporter's status a level and a detail" do
    snapshot = %{
      cameras: %{
        left: %{
          present: true,
          fps: 30.0,
          exposure_time_us: 8_000,
          analogue_gain: 2.0,
          lens_position: 428,
          colour_temperature: 5_000
        },
        right: %{present: false}
      },
      sync: %{present: true, pairs: 150, offset_max_ms: 0.7, offset_median_ms: -0.01},
      hailo: :absent,
      depth_hz: 29.9,
      cpu_percent: 61.0,
      stereo_segment_percent: 96.5,
      alignment: %{offset_rows: -0.02, band_offset_rows: [0.1, -0.1]},
      sharpness: %{left: 0.01, right: 0.012},
      quality: %{matched_percent: 60.4, mean_disparity_px: 24.2, spread_px: 15.6, jitter_px: 0.13},
      exporters: [%{id: "ros2", name: "ROS 2", status: {:ok, "Connected"}}]
    }

    assert StatusJSON.status(snapshot) == %{
             cameras: %{
               left: %{
                 present: true,
                 fps: 30.0,
                 exposureTimeUs: 8_000,
                 analogueGain: 2.0,
                 lensPosition: 428,
                 colourTemperature: 5_000
               },
               right: %{present: false}
             },
             sync: %{present: true, pairs: 150, offsetMaxMs: 0.7, offsetMedianMs: -0.01},
             hailo: "absent",
             depthHz: 29.9,
             cpuPercent: 61.0,
             stereoLoadPercent: 96.5,
             alignment: %{offsetRows: -0.02, bandOffsetRows: [0.1, -0.1]},
             sharpness: %{left: 0.01, right: 0.012},
             quality: %{
               matchedPercent: 60.4,
               meanDisparityPx: 24.2,
               spreadPx: 15.6,
               jitterPx: 0.13
             },
             exporters: [
               %{id: "ros2", name: "ROS 2", status: %{level: "ok", detail: "Connected"}}
             ]
           }
  end

  test "gives what is not measured yet as nil" do
    snapshot = %{
      cameras: %{left: %{present: false}, right: %{present: false}},
      sync: %{present: false},
      hailo: :running,
      depth_hz: 0.0,
      cpu_percent: nil,
      stereo_segment_percent: 0.0,
      alignment: nil,
      sharpness: nil,
      quality: nil,
      exporters: []
    }

    assert %{
             sync: %{present: false},
             cpuPercent: nil,
             alignment: nil,
             sharpness: nil,
             quality: nil,
             hailo: "running",
             exporters: []
           } = StatusJSON.status(snapshot)
  end
end
