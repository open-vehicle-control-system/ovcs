defmodule RosBridge.Publishers.ImuTest do
  @moduledoc false
  use ExUnit.Case, async: true
  alias OvcsDrivers.Imu.Sample
  alias RosBridge.Publishers.Imu
  alias RosBridge.Publishers.Imu.State

  defp samples(at_ns) do
    for kind <- [:rotation, :angular_velocity, :acceleration],
        do: %Sample{kind: kind, x: 0.0, y: 0.0, z: 0.0, w: 1.0, captured_at_ns: at_ns}
  end

  defp ready(at_ns) do
    Enum.reduce(samples(at_ns), %State{frame_id: "imu_link"}, &Imu.observe(&2, &1, at_ns))
  end

  test "all three streams must be fresh and advance before another publication" do
    state = ready(1_000_000_000)
    assert Imu.ready_to_publish?(state, 1_100_000_000)
    refute Imu.ready_to_publish?(state, 1_201_000_000)
    published = Map.new(state.samples, fn {kind, sample} -> {kind, sample.captured_at_ns} end)
    state = %{state | published_at_ns: published}
    refute Imu.ready_to_publish?(state, 1_100_000_000)
    [rotation | _] = samples(1_020_000_000)
    state = Imu.observe(state, rotation, 1_020_000_000)
    refute Imu.ready_to_publish?(state, 1_020_000_000)
  end

  test "new gyro and acceleration cannot disguise a stale heading" do
    state = ready(0)
    [_rotation | others] = samples(250_000_000)
    state = Enum.reduce(others, state, &Imu.observe(&2, &1, 250_000_000))
    refute Imu.ready_to_publish?(state, 250_000_000)
  end

  test "excessive sample skew or mismatched reset references prevents coalescing" do
    state = ready(1_000_000_000)
    [rotation | _] = samples(1_060_000_000)
    refute state |> Imu.observe(rotation, 1_060_000_000) |> Imu.ready_to_publish?(1_060_000_000)
    rotation = %{rotation | captured_at_ns: 1_020_000_000, reference: make_ref()}
    refute state |> Imu.observe(rotation, 1_020_000_000) |> Imu.ready_to_publish?(1_020_000_000)
  end

  test "publication keeps the capture stamp and ignores older arrivals" do
    now_ns = System.monotonic_time(:nanosecond)
    state = ready(now_ns)
    [older | _] = samples(now_ns - 1)
    assert Imu.observe(state, older, now_ns + 1) == state
    assert Imu.message(state).header.stamp == RosBridge.Timing.stamp_from_monotonic(now_ns)
  end

  test "zero quaternions and future timestamps are not published" do
    state = ready(1_000_000_000)
    refute Imu.ready_to_publish?(state, 999_000_000)
    rotation = %{state.samples.rotation | w: 0.0}

    refute Imu.ready_to_publish?(
             %{state | samples: Map.put(state.samples, :rotation, rotation)},
             1_000_000_000
           )
  end
end
