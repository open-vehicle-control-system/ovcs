# Tests run with `--no-start`; the managers subscribe to the bus in `init/1`.
{:ok, _apps} = Application.ensure_all_started(:phoenix_pubsub)
{:ok, _pubsub} = Phoenix.PubSub.Supervisor.start_link(name: OvcsBus)

ExUnit.start()
