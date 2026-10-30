defmodule VisionCore.Parameters.StorageTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias VisionCore.Parameters.{Storage, Store}
  alias VisionCore.Repo

  test "load and write answer without a running repo" do
    repo = Process.whereis(Repo)
    :ok = Supervisor.stop(repo)

    on_exit(fn ->
      {:ok, pid} = Repo.start_link()
      Process.unlink(pid)
    end)

    {values, log} = with_log(fn -> Store.load() end)
    assert values == %{}
    assert log =~ "saved parameters unavailable"
    assert {:error, _reason} = Store.write(%{"a.b.c" => 1})
  end

  test "Storage starts as :ignore on a database it cannot open" do
    Process.flag(:trap_exit, true)

    capture_log(fn ->
      assert :ignore =
               Storage.start_link(database: "/nonexistent/dir/vision.db", name: :unopenable_repo)
    end)
  end
end
