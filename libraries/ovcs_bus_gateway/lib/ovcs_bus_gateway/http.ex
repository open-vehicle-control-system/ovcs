defmodule OvcsBusGateway.Http do
  @moduledoc """
  HTTP adapter: serves the signal cache and its live updates.

  - `GET /api/signals?node=&source=&name=` lists the latest envelopes matching the filter.
  - `GET /api/signals/:node/:source/:name` returns one envelope.
  - `GET /ws?node=&source=&name=` upgrades to a WebSocket, see `OvcsBusGateway.Http.Socket`.
  - `GET /` and `/assets` serve the bus dashboard from `priv/static`.

  Started with the `:http` keyword list of the gateway config, e.g. `[port: 4100]`.
  """

  alias OvcsBusGateway.Http.Router

  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    Bandit.child_spec(plug: Router, port: Keyword.fetch!(opts, :port))
  end
end
