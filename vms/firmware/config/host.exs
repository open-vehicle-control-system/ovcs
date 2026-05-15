import Config

# Host dev runs the VMS firmware as a plain BEAM (via `./ovcs run`).
# Pull in `vms/api`'s compile-time config (namespace, Endpoint, Logger,
# Ecto, env-specific overrides) the same way a `mix phx.server` from
# inside `vms/api/` would.
import_config "../../api/config/config.exs"

# Phoenix endpoint listens by default when running under firmware.
config :vms_api, VmsApiWeb.Endpoint, server: true

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
