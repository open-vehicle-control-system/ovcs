import Config

config :vision_core, VisionCore.Repo,
  database:
    Path.join(
      System.tmp_dir!(),
      "vision_core_test_#{System.os_time()}_#{:rand.uniform(1_000_000)}.db"
    )
