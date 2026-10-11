import Config

config :vms_core,
  namespace: VmsCore,
  ecto_repos: [VmsCore.Repo],
  generators: [timestamp_type: :utc_datetime]

config :vms_core, VmsCore.Repo,
  # Next to the project on the host; the target firmware sets its own path.
  database: Path.expand("../vms_core_dev.db", Path.dirname(__ENV__.file)),
  pool_size: 5,
  stacktrace: true,
  show_sensitive_data_on_connection_error: true

# Vehicle selection lives in each firmware's config/runtime.exs: it needs
# the vehicle package compiled.

config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id],
  level: (System.get_env("LOG_LEVEL") || "debug") |> String.to_atom()

# Loads the observer, which needs wx; the target firmware does not import this file.
config :vms_core, :load_debugger_dependencies, true
# Overridden on the target by SOCKETCAND_ONLY.
config :vms_core, :socketcand_only, false
