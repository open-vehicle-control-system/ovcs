import Config

# Host dev runs the vision firmware as a plain BEAM (via `./ovcs run`),
# with `vision/api`'s config as a `mix phx.server` in `vision/api/`
# would load it.
import_config "../../api/config/config.exs"

config :vision_api, VisionApiWeb.Endpoint, server: true

# In-memory substitute for the Nerves KV store — see
# https://hexdocs.pm/nerves_runtime/readme.html#using-nerves_runtime-in-tests
config :nerves_runtime,
  kv_backend:
    {Nerves.Runtime.KVBackend.InMemory,
     contents: %{
       "nerves_fw_active" => "a",
       "a.nerves_fw_architecture" => "generic",
       "a.nerves_fw_description" => "N/A",
       "a.nerves_fw_platform" => "host",
       "a.nerves_fw_version" => "0.0.0"
     }}
