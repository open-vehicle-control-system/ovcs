import Config

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

# Read on every launch: `./ovcs run` boots the bridges with `mix run`.
config :ovcs_bus_gateway, mqtt_host: System.get_env("MQTT_HOST", "127.0.0.1")
