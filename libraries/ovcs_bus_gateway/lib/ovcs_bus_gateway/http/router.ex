defmodule OvcsBusGateway.Http.Router do
  @moduledoc """
  Routes of `OvcsBusGateway.Http`.
  """

  use Phoenix.Router, helpers: false

  pipeline :query do
    plug :fetch_query_params
  end

  scope "/", OvcsBusGateway.Http do
    pipe_through :query

    get "/api/signals", SignalController, :index
    get "/api/signals/:node/:source/:name", SignalController, :show
    get "/", DashboardController, :index
    match :*, "/*path", SignalController, :not_found
  end
end
