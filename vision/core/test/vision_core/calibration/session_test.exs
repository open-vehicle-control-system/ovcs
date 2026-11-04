defmodule VisionCore.Calibration.SessionTest do
  use ExUnit.Case, async: false

  alias VisionCore.Calibration.{Board, Session}
  alias VisionCore.Camera.Frame
  alias VisionCore.Outputs

  import ExUnit.CaptureLog

  @moduletag :capture_log

  # Names the cameras, which run only where a test registers them.
  defmodule Camera do
    def name_for(label), do: Module.concat(__MODULE__, label)
  end

  @config %VisionCore.Config{components: [stereo: [driver: Camera, left: [], right: []]]}
  @width 1280
  @height 720

  setup do
    start_supervised!({Task.Supervisor, name: VisionCore.Calibration.Tasks})
    {:ok, board} = Board.new(4, 3, 0.025)
    %{board: board}
  end

  # The corners of the 4 x 3 board, `square` px apart from `{x, y}`, each row shifted by `shear`.
  defp grid({x, y}, square, shear \\ 0) do
    for row <- 0..2,
        column <- 0..3,
        do: {x + column * square + row * shear + 0.0, y + row * square + 0.0}
  end

  # Top left, bottom right, then large and skewed: together they cover every axis.
  defp top_left, do: grid({10, 10}, 20)
  defp bottom_right, do: grid({1200, 660}, 20)
  defp large_skewed, do: grid({100, 100}, 200, 200)

  defp run_camera(label) do
    camera = spawn(fn -> Process.sleep(:infinity) end)
    Process.register(camera, Camera.name_for(label))
    on_exit(fn -> Process.exit(camera, :kill) end)
  end

  defp run_cameras, do: Enum.each(["left", "right"], &run_camera/1)

  # A detection that reports each call and answers what the frame carries.
  defp detect_stub(options \\ []) do
    test_pid = self()
    delay_ms = Keyword.get(options, :delay_ms, 0)
    in_flight = :atomics.new(1, [])

    fn frame, %Board{} ->
      running = :atomics.add_get(in_flight, 1, 1)
      send(test_pid, {:detect, frame.label, div(frame.capture_ns, 1_000_000), running})
      Process.sleep(delay_ms)
      :atomics.sub(in_flight, 1, 1)
      :erlang.binary_to_term(frame.grey)
    end
  end

  defp start_session(options \\ []) do
    start_supervised!(
      {Session, Keyword.merge([config: @config, detect_hz: 100, detect: detect_stub()], options)}
    )
  end

  defp publish(label, capture_ms, answer) do
    frame = %Frame{
      label: label,
      width: @width,
      height: @height,
      capture_ns: capture_ms * 1_000_000,
      grey: :erlang.term_to_binary(answer)
    }

    Outputs.publish({:camera_frame, Camera.name_for(label)}, {:camera_frame, frame})
  end

  defp publish_pair(capture_ms, corners) do
    publish("left", capture_ms, {:ok, corners})
    publish("right", capture_ms, {:ok, corners})
  end

  defp capture(board) do
    run_cameras()
    {:ok, %{phase: :idle}} = Session.subscribe()
    :ok = Session.start(board)
    assert_receive {:calibration_session, %{phase: :capturing, samples: 0}}
  end

  # Captures the samples that make the session good enough.
  defp capture_enough(board) do
    capture(board)

    for {corners, index} <- Enum.with_index([top_left(), bottom_right(), large_skewed()], 1) do
      publish_pair(index * 100, corners)
      assert_receive {:calibration_session, %{samples: ^index}}
    end

    assert %{good_enough: true} = Session.state()
  end

  defp count_left_detections(count) do
    receive do
      {:detect, "left", _capture_ms, _running} -> count_left_detections(count + 1)
    after
      0 -> count
    end
  end

  defp flush_detections do
    receive do
      {:detect, _label, _capture_ms, _running} -> flush_detections()
    after
      0 -> :ok
    end
  end

  defp eventually(check, attempts \\ 60) do
    cond do
      check.() -> true
      attempts > 0 -> Process.sleep(20) && eventually(check, attempts - 1)
      true -> false
    end
  end

  defp result do
    %{
      left: %{side: :left},
      right: %{side: :right},
      left_rms_px: 0.2,
      right_rms_px: 0.3,
      stereo_rms_px: 0.4,
      baseline_m: 0.06,
      fx_px: 900.0,
      samples: 3
    }
  end

  test "starts idle, with no board, sample nor result" do
    start_session()

    assert Session.state() == %{
             phase: :idle,
             board: nil,
             samples: 0,
             progress: %{x: 0.0, y: 0.0, size: 0.0, skew: 0.0},
             good_enough: false,
             detection: nil,
             result: nil,
             error: nil
           }
  end

  test "distinct corner sets become samples, a repeated one does not", %{board: board} do
    start_session()
    capture(board)

    publish_pair(0, top_left())
    assert_receive {:calibration_session, %{samples: 1, detection: detection} = state}
    assert detection.sample
    assert [{x, y} | _] = detection.left
    assert_in_delta x, 10 / @width, 1.0e-9
    assert_in_delta y, 10 / @height, 1.0e-9
    assert length(detection.right) == 12
    assert state.board == board

    publish_pair(100, top_left())

    assert_receive {:calibration_session,
                    %{samples: 1, detection: %{sample: false, left: [_ | _]}}}

    publish_pair(200, bottom_right())
    assert_receive {:calibration_session, %{samples: 2, detection: %{sample: true}} = state}
    assert state.progress.x > 0.9
    assert state.progress.y > 0.9
    refute state.good_enough
  end

  test "a pair where one side does not see the board is no sample", %{board: board} do
    start_session()
    capture(board)

    publish("left", 0, {:ok, top_left()})
    publish("right", 0, :not_found)

    assert_receive {:calibration_session,
                    %{samples: 0, detection: %{left: [_ | _], right: nil, sample: false}}}
  end

  test "frames further apart than pair_tolerance_ms are not paired", %{board: board} do
    start_session(pair_tolerance_ms: 33)
    capture(board)

    publish("left", 1_000, {:ok, top_left()})
    publish("right", 1_050, {:ok, top_left()})
    refute_receive {:detect, _label, _capture_ms, _running}, 100

    publish("right", 1_020, {:ok, top_left()})
    assert_receive {:detect, "left", 1_000, _running}
    assert_receive {:detect, "right", 1_020, _running}
  end

  test "the unit's pair_tolerance_ms is the default", %{board: board} do
    config = %VisionCore.Config{
      components: [stereo: [driver: Camera, left: [], right: [], pair_tolerance_ms: 100]]
    }

    start_session(config: config)
    capture(board)

    publish("left", 1_000, {:ok, top_left()})
    publish("right", 1_050, {:ok, top_left()})
    assert_receive {:detect, "right", 1_050, _running}
  end

  test "a slow detection never runs twice at once, and the frames in between are replaced",
       %{board: board} do
    start_session(detect: detect_stub(delay_ms: 150))
    capture(board)

    publish_pair(0, top_left())
    assert_receive {:detect, "left", 0, 1}
    for capture_ms <- 10..90//10, do: publish_pair(capture_ms, bottom_right())

    detections =
      for _call <- 1..3 do
        assert_receive {:detect, label, capture_ms, running}, 1_000
        {label, capture_ms, running}
      end

    assert detections == [{"right", 0, 1}, {"left", 90, 1}, {"right", 90, 1}]
    refute_receive {:detect, _label, _capture_ms, _running}, 300
  end

  test "detects at most :detect_hz times a second", %{board: board} do
    started_ms = System.monotonic_time(:millisecond)
    start_session(detect_hz: 4)
    capture(board)

    for capture_ms <- 0..980//20 do
      publish_pair(capture_ms, top_left())
      Process.sleep(20)
    end

    count = count_left_detections(0)
    elapsed_ms = System.monotonic_time(:millisecond) - started_ms
    assert count >= 2
    assert count <= div(elapsed_ms, 250) + 1
  end

  test "a side whose frame does not decode is logged once, until its detection works again",
       %{board: board} do
    start_session()
    capture(board)

    log =
      capture_log(fn ->
        for capture_ms <- [0, 100] do
          publish("left", capture_ms, {:error, {:jpeg, "not a JPEG"}})
          publish("right", capture_ms, {:ok, top_left()})
          assert_receive {:calibration_session, %{detection: %{left: nil, right: [_ | _]}}}
        end

        publish_pair(200, top_left())
        assert_receive {:calibration_session, %{detection: %{left: [_ | _]}}}

        publish("left", 300, {:error, {:jpeg, "not a JPEG"}})
        publish("right", 300, :not_found)
        assert_receive {:calibration_session, %{detection: %{left: nil, right: nil}}}
        :sys.get_state(Session)
      end)

    warnings = Regex.scan(~r/left detection failed: \{:jpeg, "not a JPEG"\}/, log)
    assert length(warnings) == 2
    refute log =~ "right detection failed"
  end

  test "a detection that crashes leaves the session capturing", %{board: board} do
    test_pid = self()

    detect = fn frame, _board ->
      send(test_pid, {:detect, frame.label, div(frame.capture_ns, 1_000_000), 1})

      case :erlang.binary_to_term(frame.grey) do
        :crash -> raise "detection crashed"
        answer -> answer
      end
    end

    session = start_session(detect: detect)
    capture(board)

    publish("left", 0, :crash)
    publish("right", 0, :crash)
    assert_receive {:detect, "left", 0, _running}

    publish_pair(100, top_left())
    assert_receive {:calibration_session, %{samples: 1}}
    assert Process.whereis(Session) == session
  end

  describe "with no subscriber" do
    test "detection stops, the samples stay, and a new subscriber resumes it", %{board: board} do
      start_session()
      run_cameras()
      test_pid = self()

      watcher =
        spawn(fn ->
          {:ok, _state} = Session.subscribe()
          send(test_pid, :subscribed)
          Process.sleep(:infinity)
        end)

      assert_receive :subscribed
      :ok = Session.start(board)
      publish_pair(0, top_left())
      assert eventually(fn -> Session.state().samples == 1 end)

      Process.exit(watcher, :kill)
      assert eventually(fn -> map_size(:sys.get_state(Session).subscribers) == 0 end)
      flush_detections()

      for capture_ms <- 100..500//100 do
        publish_pair(capture_ms, bottom_right())
        Process.sleep(20)
      end

      refute_receive {:detect, _label, _capture_ms, _running}, 100
      assert %{phase: :capturing, samples: 1} = Session.state()

      assert {:ok, %{phase: :capturing, samples: 1}} = Session.subscribe()
      publish_pair(1_000, bottom_right())
      assert_receive {:detect, "left", 1_000, _running}
      assert_receive {:calibration_session, %{samples: 2}}
    end
  end

  describe "solve/0" do
    test "is refused before the samples are good enough", %{board: board} do
      start_session(solve: fn _board, _size, _samples -> flunk("solved") end)
      capture(board)

      publish_pair(0, top_left())
      assert_receive {:calibration_session, %{samples: 1}}

      assert {:error, message} = Session.solve()
      assert is_binary(message)
      assert %{phase: :capturing} = Session.state()
    end

    test "runs the solver on the samples, then holds its result", %{board: board} do
      test_pid = self()

      solve = fn solve_board, size, samples ->
        send(test_pid, {:solve, solve_board, size, samples})
        Process.sleep(50)
        {:ok, result()}
      end

      start_session(solve: solve)
      capture_enough(board)

      assert :ok = Session.solve()
      assert_receive {:calibration_session, %{phase: :solving, detection: nil}}
      assert_receive {:solve, ^board, {@width, @height}, samples}

      assert samples ==
               for(
                 corners <- [top_left(), bottom_right(), large_skewed()],
                 do: %{left: corners, right: corners}
               )

      expected = result()
      assert_receive {:calibration_session, %{phase: :solved, result: ^expected, error: nil}}
    end

    test "that fails goes back to capturing with the error, the samples kept", %{board: board} do
      start_session(solve: fn _board, _size, _samples -> {:error, "no convergence"} end)
      capture_enough(board)

      assert :ok = Session.solve()

      assert_receive {:calibration_session,
                      %{phase: :capturing, error: "no convergence", samples: 3, result: nil}}

      publish_pair(1_000, grid({600, 300}, 40))
      assert_receive {:detect, "left", 1_000, _running}
    end

    test "that crashes goes back to capturing with an error", %{board: board} do
      start_session(solve: fn _board, _size, _samples -> raise "solver crashed" end)
      capture_enough(board)

      assert :ok = Session.solve()
      assert_receive {:calibration_session, %{phase: :capturing, error: error, samples: 3}}
      assert is_binary(error)
    end
  end

  describe "apply/0" do
    defp solved(board, commit) do
      start_session(solve: fn _board, _size, _samples -> {:ok, result()} end, commit: commit)
      capture_enough(board)
      :ok = Session.solve()
      assert_receive {:calibration_session, %{phase: :solved}}
    end

    test "commits the solved calibrations and ends the session", %{board: board} do
      test_pid = self()

      solved(board, fn config, calibrations ->
        send(test_pid, {:commit, config, calibrations})
        Process.sleep(50)
        :ok
      end)

      assert :ok = Session.apply()
      assert_receive {:calibration_session, %{phase: :applying}}
      assert_receive {:commit, @config, %{left: %{side: :left}, right: %{side: :right}}}

      assert_receive {:calibration_session,
                      %{phase: :idle, board: nil, samples: 0, result: nil, error: nil}}

      assert unsubscribed?(Process.whereis(Session))
    end

    test "that is refused stays solved, with the refusal", %{board: board} do
      solved(board, fn _config, _calibrations -> {:error, "the unit refused it"} end)

      assert :ok = Session.apply()

      expected = result()

      assert_receive {:calibration_session,
                      %{phase: :solved, error: "the unit refused it", result: ^expected}}
    end

    test "is refused before a solve", %{board: board} do
      start_session(commit: fn _config, _calibrations -> flunk("committed") end)
      capture(board)

      assert {:error, _message} = Session.apply()
    end

    test "whose commit crashes stays solved, with an error", %{board: board} do
      solved(board, fn _config, _calibrations -> raise "commit crashed" end)

      assert :ok = Session.apply()

      expected = result()

      assert_receive {:calibration_session, %{phase: :solved, error: error, result: ^expected}}

      assert is_binary(error)
    end

    test "cannot be cancelled while it runs", %{board: board} do
      test_pid = self()

      solved(board, fn _config, _calibrations ->
        send(test_pid, :committing)
        Process.sleep(100)
        :ok
      end)

      :ok = Session.apply()
      assert_receive :committing
      assert {:error, _message} = Session.cancel()
      assert_receive {:calibration_session, %{phase: :idle}}
    end
  end

  test "cancel/0 during a solve kills it and ends the session", %{board: board} do
    test_pid = self()

    solve = fn _board, _size, _samples ->
      send(test_pid, {:solving, self()})
      Process.sleep(:infinity)
    end

    start_session(solve: solve)
    capture_enough(board)
    :ok = Session.solve()
    assert_receive {:solving, solver}
    monitor = Process.monitor(solver)

    assert :ok = Session.cancel()
    assert_receive {:DOWN, ^monitor, :process, ^solver, _reason}
    assert_receive {:calibration_session, %{phase: :idle, samples: 0}}
    assert %{phase: :idle} = Session.state()
  end

  defp frame_keys,
    do: for(label <- ["left", "right"], do: {:camera_frame, Camera.name_for(label)})

  defp subscribed?(session), do: Enum.all?(frame_keys(), &(session in Outputs.subscribers(&1)))

  defp unsubscribed?(session),
    do: Enum.all?(frame_keys(), &(session not in Outputs.subscribers(&1)))

  test "takes the camera frames from start/1, across the cameras' restarts, until cancel/0",
       %{board: board} do
    session = start_session()
    assert unsubscribed?(session)

    capture(board)
    assert subscribed?(session)

    Process.exit(Process.whereis(Camera.name_for("left")), :kill)
    eventually(fn -> Process.whereis(Camera.name_for("left")) == nil end)
    run_camera("left")
    publish_pair(100, top_left())
    assert_receive {:calibration_session, %{samples: 1}}

    :ok = Session.cancel()
    assert unsubscribed?(session)
  end

  test "cancel/0 while capturing ends the session", %{board: board} do
    start_session()
    capture(board)

    assert :ok = Session.cancel()
    assert_receive {:calibration_session, %{phase: :idle, board: nil}}
    assert :ok = Session.start(board)
  end

  describe "start/1" do
    test "is refused while the stereo cameras are not running", %{board: board} do
      start_session()

      assert Session.start(board) == {:error, "the stereo cameras are not running"}

      run_camera("left")
      assert Session.start(board) == {:error, "the stereo cameras are not running"}
      assert %{phase: :idle} = Session.state()
    end

    test "is refused while a session runs", %{board: board} do
      start_session()
      capture(board)

      assert {:error, _message} = Session.start(board)
      assert %{phase: :capturing} = Session.state()
    end
  end
end
