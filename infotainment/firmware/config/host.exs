import Config

# Host dev runs the infotainment firmware as a plain BEAM (via
# `./ovcs run`). Pull in `infotainment/api`'s compile-time config
# (namespace, Endpoint, Logger, Ecto, env-specific overrides) the
# same way `mix phx.server` from inside `infotainment/api/` would.
import_config "../../api/config/config.exs"

config :infotainment_api, InfotainmentApiWeb.Endpoint, server: true

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
