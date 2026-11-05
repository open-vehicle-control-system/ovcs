defmodule BNO085.I2CTest do
  use ExUnit.Case, async: true

  alias BNO085.I2C
  alias OvcsDrivers.Imu.Sample

  # Each fixture below is a minimal SH-2 cargo as the chip would
  # write it on the I²C bus: 4 bytes of SHTP header (cargo length
  # little-endian, channel byte, sequence byte) followed by one
  # report (1 byte report id, then the report-specific payload).
  # Channel 3 is the "input sensor reports" channel; report ids
  # match `@accelerometer_report` / `@calibrated_gyroscope_report`
  # / `@game_rotation_vector_report` in `BNO085.I2C`.

  describe "parse_cargo/1 — accelerometer (report 0x01, 10-byte body)" do
    test "extracts raw signed int16 axes in little-endian order" do
      # cargo_length = 4 (header) + 10 (one accel report) = 14.
      # axes x=256 → <<0,1>>, y=-256 → <<0,255>>, z=512 → <<0,2>>.
      cargo = <<14, 0, 3, 0, 0x01, 1, 2, 0, 0, 1, 0, 0xFF, 0, 2>>

      assert {:ok, %{header: %{channel: 3}, reports: reports}} = I2C.parse_cargo(cargo)
      assert [report] = reports
      assert report.id == 0x01
      assert report.name == "accelerometer"
      assert report.sequence_number == 1
      assert report.status == 2
      assert report.delay == 0
      assert report.x == 256
      assert report.y == -256
      assert report.z == 512
    end
  end

  describe "parse_cargo/1 — calibrated_gyroscope (report 0x02)" do
    test "shares the accelerometer body shape" do
      cargo = <<14, 0, 3, 0, 0x02, 7, 0, 0, 100, 0, 50, 0, 0, 0>>

      assert {:ok, %{reports: [report]}} = I2C.parse_cargo(cargo)
      assert report.id == 0x02
      assert report.name == "calibrated_gyroscope"
      assert {report.x, report.y, report.z} == {100, 50, 0}
    end
  end

  describe "parse_cargo/1 — game_rotation_vector (report 0x08, 12-byte body)" do
    test "extracts the quaternion" do
      # 1 byte id + seq + status + delay + 4 × int16 quat = 12-byte
      # report body. cargo_length = 4 + 12 = 16.
      # i=0, j=0, k=0, real=16_383 (≈ Q14 1.0).
      cargo = <<16, 0, 3, 0, 0x08, 9, 3, 0, 0, 0, 0, 0, 0, 0, 0xFF, 0x3F>>

      assert {:ok, %{reports: [report]}} = I2C.parse_cargo(cargo)
      assert report.id == 0x08
      assert report.name == "game_rotation_vector"
      assert {report.i, report.j, report.k, report.real} == {0, 0, 0, 16_383}
    end
  end

  describe "build_sample/1 — Q-point scaling" do
    test "accelerometer is Q8 → m/s²" do
      raw = %{id: 0x01, name: "accelerometer", x: 256, y: -256, z: 512}
      assert %Sample{kind: :acceleration, x: 1.0, y: -1.0, z: 2.0} = I2C.build_sample(raw)
    end

    test "calibrated_gyroscope is Q9 → rad/s" do
      raw = %{id: 0x02, name: "calibrated_gyroscope", x: 512, y: -512, z: 1024}
      assert %Sample{kind: :angular_velocity, x: 1.0, y: -1.0, z: 2.0} = I2C.build_sample(raw)
    end

    test "game_rotation_vector is Q14 → unit-quaternion components" do
      # real = 16_383 should land at 16_383/16384 ≈ 0.99993896 — the
      # exact value we see on the wire from the dummy driver.
      raw = %{id: 0x08, name: "game_rotation_vector", i: 0, j: 0, k: 0, real: 16_383}

      sample = I2C.build_sample(raw)
      assert sample.kind == :rotation
      assert sample.x == 0.0
      assert sample.y == 0.0
      assert sample.z == 0.0
      assert_in_delta sample.w, 0.99993896484375, 1.0e-12
    end

    test "unknown report id returns nil" do
      assert I2C.build_sample(%{id: 0x99}) == nil
    end
  end

  describe "parse_cargo/1 + build_sample/1 — full intake path" do
    test "raw accelerometer cargo bytes → fully-scaled Sample" do
      # Same accel cargo as the parse test above; result should match
      # `OvcsDrivers.Imu.Dummy`'s static accel fixture once divided
      # by Q8 = 256.
      cargo = <<14, 0, 3, 0, 0x01, 1, 2, 0, 0xD0, 0xFF, 0xD9, 0xFF, 0xA8, 0xFF>>
      # Raw int16 LE: 0xFFD0 = -48, 0xFFD9 = -39, 0xFFA8 = -88.

      assert {:ok, %{reports: [report]}} = I2C.parse_cargo(cargo)
      sample = I2C.build_sample(report)

      assert sample.kind == :acceleration
      assert_in_delta sample.x, -48 / 256, 1.0e-12
      assert_in_delta sample.y, -39 / 256, 1.0e-12
      assert_in_delta sample.z, -88 / 256, 1.0e-12
    end
  end

  defmodule Transport do
    @moduledoc false
    def write(_bus, _address, bytes) do
      send(self(), {:i2c_write, bytes})
      :ok
    end

    def read(_bus, _address, _length) do
      case Process.get(:i2c_reads, []) do
        [packet | remaining] ->
          Process.put(:i2c_reads, remaining)
          packet

        [] ->
          {:error, :read_failed}
      end
    end
  end

  defp streaming_state do
    %{
      I2C.new_state(:bus, transport: Transport)
      | chip_ready?: true,
        listeners: [self()],
        requested_enables: [:accelerometer, :calibrated_gyroscope, :game_rotation_vector]
    }
  end

  defp cargo(reports), do: %{header: %{channel: 3}, reports: reports}

  defp gyro(sequence, status \\ 3, delay \\ 0),
    do: %{id: 2, sequence_number: sequence, status: status, delay: delay, x: 0, y: 0, z: 512}

  test "timestamps include signed base, rebase and the high delay bits" do
    bytes = <<9, 0, 3, 0, 0xFB, -10::little-signed-32>>
    assert {:ok, %{reports: [%{base_delta: -10}]}} = I2C.parse_cargo(bytes)
    reports = [%{id: 0xFB, base_delta: 300}, %{id: 0xFA, base_delta: 10}, gyro(1, 7, 2)]
    state = streaming_state()
    I2C.handle_cargo(state, cargo(reports), 1_000_000_000)
    assert_receive {:"$gen_cast", {:imu_sample, sample}}
    assert sample.captured_at_ns == 996_800_000
    assert sample.received_at_ns == 1_000_000_000
    assert sample.accuracy == 3
    assert sample.sequence == 1
    assert sample.reference == state.reference
  end

  test "duplicate reports cannot refresh sensor health" do
    state = I2C.handle_cargo(streaming_state(), cargo([gyro(255)]), 0)
    assert_receive {:"$gen_cast", {:imu_sample, _sample}}
    state = I2C.handle_cargo(state, cargo([gyro(255)]), 600_000_000)
    refute_receive {:"$gen_cast", {:imu_sample, _sample}}
    assert :calibrated_gyroscope in I2C.missing_sensors(state, 600_000_000)
    I2C.handle_cargo(state, cargo([gyro(0)]), 600_000_000)
    assert_receive {:"$gen_cast", {:imu_sample, %Sample{sequence: 0}}}
  end

  test "one live report kind does not hide missing streams" do
    state = I2C.handle_cargo(streaming_state(), cargo([gyro(1)]), 0)
    assert I2C.missing_sensors(state, 100_000_000) == [:accelerometer, :game_rotation_vector]
    assert length(I2C.missing_sensors(state, 501_000_000)) == 3
  end

  test "a runtime reset renews the orientation reference and reenables every requested stream" do
    state = streaming_state()
    reset = %{header: %{channel: 1}, reports: [%{id: 1}]}
    next = I2C.handle_cargo(state, reset, 0)
    assert next.reference != state.reference
    assert next.last_reports == %{}
    assert next.chip_ready?

    for {id, sequence} <- [{1, 0}, {2, 1}, {8, 2}] do
      assert_receive {:i2c_write,
                      <<21, 0, 2, ^sequence, 0xFD, ^id, 0, 0, 0, 20_000::little-32, 0::64>>}
    end

    Process.cancel_timer(next.verify_ref)
  end

  test "repeated stream failures reset instead of abandoning recovery" do
    {:noreply, state} =
      I2C.handle_info(:verify_enables, %{streaming_state() | enable_attempts: 5})

    refute state.chip_ready?
    assert_receive {:i2c_write, <<5, 0, 1, 0, 1>>}
    assert state.ready_ref != nil
    Process.cancel_timer(state.ready_ref)
  end

  test "transport errors preserve the driver for the next bounded poll" do
    state = streaming_state()
    assert {:noreply, ^state} = I2C.handle_info(:loop, state)
  end

  test "each poll drains at most its packet budget" do
    packets =
      Enum.flat_map(0..8, fn sequence ->
        [
          {:ok, <<14, 0, 3, sequence>>},
          {:ok, <<14, 0, 3, sequence, 2, sequence, 3, 0, 0, 0, 0, 0, 0, 2>>}
        ]
      end)

    Process.put(:i2c_reads, packets)
    {:noreply, state} = I2C.handle_info(:loop, streaming_state())
    assert state.last_reports[2].sequence == 7
    assert length(Process.get(:i2c_reads)) == 2
    {:noreply, state} = I2C.handle_info(:loop, state)
    assert state.last_reports[2].sequence == 8
  end

  test "report intervals are configurable and validated" do
    state = I2C.new_state(:bus, transport: Transport, report_interval_us: 10_000)

    {:noreply, state} =
      I2C.handle_cast({:enable, :game_rotation_vector}, %{state | chip_ready?: true})

    assert_receive {:i2c_write, <<21, 0, 2, 0, 0xFD, 8, 0, 0, 0, 10_000::little-32, 0::64>>}
    Process.cancel_timer(state.verify_ref)
    assert_raise ArgumentError, fn -> I2C.new_state(:bus, report_interval_us: 0) end
  end
end
