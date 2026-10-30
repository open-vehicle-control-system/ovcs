import Config

config :vision_core, VisionCore.Repo,
  database:
    Path.join(System.tmp_dir!(), "vision_core_test_#{System.unique_integer([:positive])}.db")
