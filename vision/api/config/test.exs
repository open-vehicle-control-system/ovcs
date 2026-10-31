import Config

config :vision_api, VisionApiWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4102],
  secret_key_base: "Wq8sJ2nV5bX1cM9kL4hG7fD3aS6zP0oI8uY2tR5eW1qA9sD4fG7hJ0kL3zX6cV9b",
  server: false

config :logger, level: :warning

config :phoenix, :plug_init_mode, :runtime

config :vision_core, ecto_repos: [VisionCore.Repo]

config :vision_core, VisionCore.Repo,
  database:
    Path.join(
      System.tmp_dir!(),
      "vision_api_test_#{System.os_time()}_#{:rand.uniform(1_000_000)}.db"
    ),
  pool_size: 1
