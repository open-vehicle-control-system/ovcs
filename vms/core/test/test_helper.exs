# Tests run with `--no-start`, so callbacks run without Cantastic or a CAN interface.
# The bus is the exception: started once here, since async modules would clash over
# its global name `OvcsBus`, and after `phoenix_pubsub`, without which it fails to start.
{:ok, _apps} = Application.ensure_all_started(:phoenix_pubsub)
{:ok, _pubsub} = Phoenix.PubSub.Supervisor.start_link(name: OvcsBus)

ExUnit.start()
