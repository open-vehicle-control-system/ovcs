defmodule VisionCore.Stereo.AlignmentCorrectionTest do
  use ExUnit.Case, async: true

  alias VisionCore.Stereo.{AlignmentCorrection, Pipeline}

  defp start(offset \\ 0.0, opts \\ []) do
    test_pid = self()
    current = :counters.new(1, [])
    :counters.put(current, 1, round(offset * 1000))

    {:ok, pid} =
      AlignmentCorrection.start_link(
        [
          name: nil,
          subscribe: false,
          current_offset: fn -> :counters.get(current, 1) / 1000 end,
          set_offset: fn rows ->
            :counters.put(current, 1, round(rows * 1000))
            send(test_pid, {:set, rows})
            :ok
          end
        ] ++ opts
      )

    pid
  end

  defp tick(pid, offset) do
    alignment = if offset, do: %{offset_rows: offset, band_offset_rows: []}
    send(pid, {:vision_status, %{alignment: alignment}})
  end

  test "corrects an offset that lasts, by more than it reads, as readings fall short" do
    pid = start()
    for _ <- 1..5, do: tick(pid, 1.0)
    assert_receive {:set, rows}
    assert_in_delta rows, 1.5, 1.0e-6
  end

  test "builds on the correction in force" do
    pid = start(1.0)
    for _ <- 1..5, do: tick(pid, 0.5)
    assert_receive {:set, rows}
    assert_in_delta rows, 1.75, 1.0e-6
  end

  test "leaves small or passing offsets alone" do
    pid = start()
    for _ <- 1..5, do: tick(pid, 0.08)
    for offset <- [3.0, 0.0, 0.0, 0.1, 0.0], do: tick(pid, offset)
    refute_receive {:set, _rows}, 100
  end

  test "ignores ticks without a measurement" do
    pid = start()
    for _ <- 1..5, do: tick(pid, nil)
    refute_receive {:set, _rows}, 100
  end

  test "stays within the largest correction" do
    pid = start(5.5)
    for _ <- 1..5, do: tick(pid, 2.0)
    assert_receive {:set, 6.0}
  end

  test "subscribes to the status once it runs, and keeps running" do
    {:ok, pid} = AlignmentCorrection.start_link(name: nil, set_offset: fn _ -> :ok end)
    send(pid, :subscribe)
    Process.sleep(50)
    assert Process.alive?(pid)
  end

  test "corrects nothing while switched off, and starts over when switched on" do
    pid = start()
    assert AlignmentCorrection.enabled?(pid)
    :ok = AlignmentCorrection.set_enabled(pid, false)
    refute AlignmentCorrection.enabled?(pid)

    for _ <- 1..5, do: tick(pid, 1.0)
    refute_receive {:set, _rows}, 100

    :ok = AlignmentCorrection.set_enabled(pid, true)
    for _ <- 1..4, do: tick(pid, 1.0)
    refute_receive {:set, _rows}, 100
    tick(pid, 1.0)
    assert_receive {:set, _rows}
  end

  test "starts switched off with enabled: false" do
    refute AlignmentCorrection.enabled?(start(0.0, enabled: false))
  end

  test "waits for fresh measurements after a correction" do
    pid = start()
    for _ <- 1..5, do: tick(pid, 1.0)
    assert_receive {:set, _rows}
    for _ <- 1..4, do: tick(pid, 1.0)
    refute_receive {:set, _rows}, 100
  end

  test "moves the pipeline's Rectification stage by default" do
    calibration = Path.expand("../../support/calibration", __DIR__)

    {:ok, pipeline} =
      Pipeline.start_link(
        name: :alignment_correction_pipeline,
        left_calibration_path: Path.join(calibration, "identity_left.yaml"),
        right_calibration_path: Path.join(calibration, "identity_right.yaml"),
        width: 64,
        height: 48
      )

    {:ok, _} = Pipeline.set_options(pipeline, :rectification, right_row_offset: 1.0)
    {:ok, pid} = AlignmentCorrection.start_link(name: nil, subscribe: false, pipeline: pipeline)
    for _ <- 1..5, do: tick(pid, 1.0)
    :sys.get_state(pid)

    rectification = Enum.find(Pipeline.stage_options(pipeline), &(&1.stage == :rectification))
    assert_in_delta rectification.values.right_row_offset, 2.5, 1.0e-6
  end
end
