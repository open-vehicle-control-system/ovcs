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
  # / `@rotation_vector_report` in `BNO085.I2C`.

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

  describe "parse_cargo/1 — rotation_vector (report 0x05, 14-byte body)" do
    test "extracts the quaternion + drops accuracy_estimate" do
      # 1 byte id + seq + status + delay + 4 × int16 quat + int16 accuracy
      # = 14-byte report body. cargo_length = 4 + 14 = 18.
      # i=0, j=0, k=0, real=16_383 (≈ Q14 1.0), accuracy=42 (ignored).
      cargo = <<18, 0, 3, 0, 0x05, 9, 3, 0, 0, 0, 0, 0, 0, 0, 0xFF, 0x3F, 42, 0>>

      assert {:ok, %{reports: [report]}} = I2C.parse_cargo(cargo)
      assert report.id == 0x05
      assert report.name == "rotation_vector"
      assert {report.i, report.j, report.k, report.real} == {0, 0, 0, 16_383}
      refute Map.has_key?(report, :accuracy_estimate)
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

    test "rotation_vector is Q14 → unit-quaternion components" do
      # real = 16_383 should land at 16_383/16384 ≈ 0.99993896 — the
      # exact value we see on the wire from the dummy driver.
      raw = %{id: 0x05, name: "rotation_vector", i: 0, j: 0, k: 0, real: 16_383}

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
      # `BNO085.Dummy`'s static fixture once divided by Q8 = 256.
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
end
