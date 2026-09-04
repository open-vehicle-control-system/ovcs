# `mix test --no-start` keeps the application tree down, which is what
# lets component callbacks be driven directly without Cantastic or a
# CAN interface present. The pub/sub bus is the one exception: it is
# not a peripheral, it is where components publish their results, so a
# test asserting on what a component *emits* needs it up.
#
# `phoenix_pubsub` has to be started first — its PG2 adapter joins a
# process group owned by that application, and without it the adapter
# fails to start with a confusing "no process" on `Phoenix.PubSub`.
#
# Started here rather than per-module because the instance is
# registered under the global name `OvcsBus`, so competing
# `start_supervised!` calls from async modules would clash over it.
{:ok, _apps} = Application.ensure_all_started(:phoenix_pubsub)
{:ok, _pubsub} = Phoenix.PubSub.Supervisor.start_link(name: OvcsBus)

ExUnit.start()
