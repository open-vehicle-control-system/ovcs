defmodule VmsCore.Components.OVCS.ThrottleCalibrationPersistenceTest do
  use ExUnit.Case, async: false

  alias VmsCore.{Models.ThrottleCalibration, Repo}
  alias VmsCore.Components.OVCS.ThrottlePedal

  @old %{
    low_raw_throttle_a: 1000,
    low_raw_throttle_b: 2000,
    high_raw_throttle_a: 9000,
    high_raw_throttle_b: 10_000
  }
  @new %{
    low_raw_throttle_a: 1500,
    low_raw_throttle_b: 2500,
    high_raw_throttle_a: 9500,
    high_raw_throttle_b: 10_500
  }

  setup_all do
    {:ok, _} = Application.ensure_all_started(:ecto_sqlite3)

    migrations =
      for path <- Path.wildcard(Application.app_dir(:vms_core, "priv/repo/migrations/*.exs")) do
        {version, _suffix} = path |> Path.basename() |> Integer.parse()
        [{module, _beam}] = Code.require_file(path)
        {version, module}
      end

    %{migrations: migrations}
  end

  setup %{migrations: migrations} do
    database =
      Path.join(
        System.tmp_dir!(),
        "vms-calibration-test-#{System.unique_integer([:positive])}.db"
      )

    start_supervised!({Repo, database: database, pool_size: 1, log: false})

    Ecto.Migrator.run(Repo, migrations, :up,
      all: true,
      log: false
    )

    on_exit(fn ->
      for suffix <- ["", "-wal", "-shm"], do: File.rm(database <> suffix)
    end)

    :ok
  end

  defp store_snapshot(boundaries, timestamp) do
    for {key, value} <- boundaries do
      Repo.insert!(%ThrottleCalibration{
        key: Atom.to_string(key),
        value: value,
        inserted_at: timestamp,
        updated_at: timestamp
      })
    end
  end

  defp load_pedal do
    {:ok, state} =
      ThrottlePedal.init(%{
        controller: nil,
        throttle_a_pin: :a,
        throttle_b_pin: :b,
        cross_check_tolerance: "0.1",
        cross_check_hold_ms: 100
      })

    {:ok, :cancel} = :timer.cancel(state.loop_timer)
    state
  end

  test "reloads the newest calibration when two snapshots share a timestamp" do
    store_snapshot(@old, ~N[2026-01-01 00:00:00])
    store_snapshot(@new, ~N[2026-01-01 00:00:00])

    assert Map.take(load_pedal(), Map.keys(@new)) == @new
  end

  for action <- [:disable_calibration_mode, {:calibrate, "calibrate_boundaries"}] do
    test "#{inspect(action)} commits all four new boundaries" do
      store_snapshot(@old, ~N[2026-01-01 00:00:00])

      state =
        load_pedal() |> Map.merge(@new) |> Map.put(:throttle_calibration_status, "in_progress")

      assert {:reply, :ok, saved} =
               ThrottlePedal.handle_call(unquote(Macro.escape(action)), nil, state)

      assert saved.throttle_calibration_status == "disabled"
      assert Map.take(load_pedal(), Map.keys(@new)) == @new
    end

    test "#{inspect(action)} rolls back every boundary when the fourth insert fails" do
      store_snapshot(@old, ~N[2026-01-01 00:00:00])

      Repo.query!("""
      CREATE TRIGGER reject_last_boundary BEFORE INSERT ON throttle_calibrations
      WHEN NEW.key = 'high_raw_throttle_b'
      BEGIN SELECT RAISE(ABORT, 'injected storage failure'); END
      """)

      state =
        load_pedal() |> Map.merge(@new) |> Map.put(:throttle_calibration_status, "in_progress")

      assert_raise Exqlite.Error, fn ->
        ThrottlePedal.handle_call(unquote(Macro.escape(action)), nil, state)
      end

      assert Repo.aggregate(ThrottleCalibration, :count) == 4
      assert Map.take(load_pedal(), Map.keys(@old)) == @old
    end
  end
end
