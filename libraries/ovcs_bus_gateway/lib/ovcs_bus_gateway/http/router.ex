defmodule OvcsBusGateway.Http.Router do
  @moduledoc """
  Routes of `OvcsBusGateway.Http`: the `signals`, `nodes`, `adapters` and `configurations`
  resources under `/api`, following JSON:API, a JSON:API 404 for any other `/api` path, and the
  dashboard on every other path.
  """

  use Phoenix.Router, helpers: false

  import OvcsBusGateway.Http.JsonApi, only: [put_media_type: 2]

  pipeline :jsonapi do
    plug :fetch_query_params
    plug :put_media_type
  end

  scope "/api", OvcsBusGateway.Http do
    pipe_through :jsonapi

    get "/signals", SignalsController, :index
    get "/signals/:node/:source/:name", SignalsController, :show
    get "/nodes", NodesController, :index
    get "/nodes/:id", NodesController, :show
    get "/adapters", AdaptersController, :index
    get "/configuration", ConfigurationController, :show
  end

  scope "/api", OvcsBusGateway.Http do
    match :*, "/*path", NotFoundController, :show
  end

  scope "/", OvcsBusGateway.Http do
    get "/*path", DashboardController, :index
  end
end
