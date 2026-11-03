defmodule VisionCore.Stereo.AlignmentCorrectionTest do
  use ExUnit.Case, async: false

  import VisionCore.Stereo.TestHelpers, only: [calibration_path: 2]

  alias VisionCore.Stereo.{AlignmentCorrection, Pipeline, Stage, VehicleRectification}

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

  test "leaves the rows alone without a rectification stage to move them" do
    test_pid = self()

    {:ok, pid} =
      AlignmentCorrection.start_link(
        name: nil,
        subscribe: false,
        current_offset: fn -> nil end,
        set_offset: fn rows -> send(test_pid, {:set, rows}) end
      )

    for _ <- 1..5, do: tick(pid, 1.0)
    refute_receive {:set, _rows}, 100
    assert Process.alive?(pid)
  end

  # Stands in for VisionCore.Status: tells the test who subscribes.
  defmodule Status do
    use GenServer

    def start_link(test), do: GenServer.start_link(__MODULE__, test, name: VisionCore.Status)

    @impl GenServer
    def init(test), do: {:ok, test}

    @impl GenServer
    def handle_call({:subscribe, pid}, _from, test) do
      send(test, {:subscribed, pid})
      {:reply, :ok, test}
    end
  end

  test "subscribes to the status, and again once it restarts" do
    start_supervised!({Status, self()})
    {:ok, pid} = AlignmentCorrection.start_link(name: nil, set_offset: fn _ -> :ok end)
    assert_receive {:subscribed, ^pid}, 1_000

    stop_supervised!(Status)
    start_supervised!({Status, self()})
    assert_receive {:subscribed, ^pid}, 2_000
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
    pipeline = start_pipeline(Pipeline.default_stages())
    assert_in_delta corrected_offset(pipeline, :rectification), 2.5, 1.0e-6
  end

  test "moves the stage that declares right_row_offset, whatever its name" do
    pipeline = start_pipeline([VehicleRectification | tl(Pipeline.default_stages())])
    assert_in_delta corrected_offset(pipeline, :vehicle_rectification), 2.5, 1.0e-6
  end

  defp start_pipeline(stages) do
    start_supervised!(
      {Pipeline,
       name: :alignment_correction_pipeline,
       stages: stages,
       left_calibration_path: calibration_path(:identity, :left),
       right_calibration_path: calibration_path(:identity, :right),
       width: 64,
       height: 48,
       defn_options: [compiler: EXLA]}
    )
  end

  # The right_row_offset of stage `name` once the correction followed an offset of a row from 1.
  defp corrected_offset(pipeline, name) do
    {:ok, _} = Pipeline.set_options(pipeline, name, right_row_offset: 1.0)
    {:ok, pid} = AlignmentCorrection.start_link(name: nil, subscribe: false, pipeline: pipeline)
    for _ <- 1..5, do: tick(pid, 1.0)
    :sys.get_state(pid)

    Enum.find(Pipeline.stage_options(pipeline), &(&1.stage == name)).values.right_row_offset
  end

  test "finds the stage it moves and the one it follows by what they declare, whatever their names" do
    stages = [
      %{stage: :vehicle_rectification, module: VehicleRectification},
      %{stage: :sharpness, module: Stage.Sharpness},
      %{stage: :row_alignment, module: Stage.RowAlignment}
    ]

    assert %{stage: :vehicle_rectification} = AlignmentCorrection.offset_stage(stages)
    assert %{stage: :row_alignment} = AlignmentCorrection.alignment_stage(stages)
    assert AlignmentCorrection.offset_stage(tl(stages)) == nil
    assert AlignmentCorrection.alignment_stage(Enum.take(stages, 2)) == nil
  end

  # A vehicle's own measure of the row offset.
  defmodule AlignmentMeasure do
    @behaviour VisionCore.Stereo.Stage

    def init(_opts, _context), do: {:ok, nil}
    def requires, do: [:left, :right, :disparity]
    def provides, do: [:alignment]
    def run(pair, state), do: {:ok, pair, state}
  end

  test "refuses two modules that declare right_row_offset or provide :alignment, leaving a module listed twice to the pipeline" do
    assert AlignmentCorrection.check_stages!([
             VehicleRectification | tl(Pipeline.default_stages())
           ]) == :ok

    assert_raise ArgumentError,
                 "#{inspect(Stage.Rectification)} and #{inspect(VehicleRectification)} both " <>
                   "declare right_row_offset: the row correction moves one stage's rows",
                 fn ->
                   AlignmentCorrection.check_stages!(
                     Pipeline.default_stages() ++ [VehicleRectification]
                   )
                 end

    assert_raise ArgumentError,
                 "#{inspect(Stage.RowAlignment)} and #{inspect(AlignmentMeasure)} both " <>
                   "provide :alignment: the row correction follows one stage's measure",
                 fn ->
                   AlignmentCorrection.check_stages!(
                     Pipeline.default_stages() ++ [{AlignmentMeasure, []}]
                   )
                 end

    assert AlignmentCorrection.check_stages!(
             Pipeline.default_stages() ++ [Stage.Rectification, Stage.RowAlignment]
           ) == :ok
  end
end
