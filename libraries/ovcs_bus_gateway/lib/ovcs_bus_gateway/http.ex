defmodule OvcsBusGateway.Http do
  @moduledoc """
  HTTP adapter: a Phoenix endpoint, `OvcsBusGateway.Http.Endpoint`, serving the signal cache
  and its live updates.

  - `GET /api/signals?filter[node]=&filter[source]=&filter[name]=` lists the latest signals
    matching the filter, as JSON:API `signals` resources, see
    `OvcsBusGateway.Http.SignalsController`.
  - `GET /api/signals/:node/:source/:name` returns one.
  - `/sockets/dashboard` is a Phoenix Channels socket; its `signals` channel streams the
    envelopes, see `OvcsBusGateway.Http.SignalsChannel`.
  - Any other path serves the bus dashboard from `priv/static`.

  Started with the `:http` keyword list of the gateway config, e.g. `[port: 4100]`. The
  endpoint is configured from these options alone, not from the host application's config.
  """

  alias OvcsBusGateway.Http.Endpoint

  @default_port 4100

  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    endpoint_config = [
      adapter: Bandit.PhoenixAdapter,
      http: [port: Keyword.get(opts, :port, @default_port)],
      server: true,
      pubsub_server: OvcsBusGateway.PubSub,
      render_errors: [formats: [json: OvcsBusGateway.Http.ErrorJSON], layout: false]
    ]

    %{
      id: __MODULE__,
      type: :supervisor,
      start:
        {Supervisor, :start_link,
         [
           [{Phoenix.PubSub, name: OvcsBusGateway.PubSub}, {Endpoint, endpoint_config}],
           [strategy: :rest_for_one]
         ]}
    }
  end

  @doc """
  Builds an `t:OvcsBusGateway.filter/0` from the `node`, `source` and `name` join params of the
  `signals` channel that are present and non-empty.
  """
  @spec filter(map()) :: OvcsBusGateway.filter()
  def filter(params) do
    for key <- ~w(node source name),
        value = params[key],
        is_binary(value) and value != "",
        into: %{},
        do: {String.to_existing_atom(key), value}
  end
end
