# vision_core's saved parameter values: one database file per run, removed after it.
database = Application.fetch_env!(:vision_core, VisionCore.Repo)[:database]
remove_database = fn -> Enum.each(["", "-wal", "-shm"], &File.rm(database <> &1)) end
remove_database.()
ExUnit.after_suite(fn _results -> remove_database.() end)

# `mix test --no-start` starts nothing; the endpoint and PubSub back every channel and conn test.
{:ok, _apps} = Application.ensure_all_started(:vision_api)
ExUnit.start()
