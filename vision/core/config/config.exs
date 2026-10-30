import Config

config :vision_core, ecto_repos: [VisionCore.Repo]

config :vision_core, VisionCore.Repo,
  database: Path.expand("../vision_core_dev.db", Path.dirname(__ENV__.file)),
  pool_size: 1

if File.exists?(Path.join(__DIR__, "#{config_env()}.exs")) do
  import_config "#{config_env()}.exs"
end
