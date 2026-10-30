defmodule VisionApiWeb.Router do
  use VisionApiWeb, :router

  pipeline :api do
    plug :accepts, ["json"]
  end

  pipeline :jsonapi do
    plug :accepts, ["jsonapi", "json"]
  end

  scope "/api", VisionApiWeb do
    pipe_through :jsonapi
    get "/parameter-groups", ParameterGroupController, :index
    get "/parameters", ParameterController, :index
    get "/parameters/:id", ParameterController, :show
    patch "/parameters/:id", ParameterController, :update
    post "/parameter-saves", ParameterActionController, :save
    post "/parameter-discards", ParameterActionController, :discard
    post "/parameter-resets", ParameterActionController, :reset
    get "/parameter-export", ParameterActionController, :export
  end

  scope "/api", VisionApiWeb do
    pipe_through :api
    get "/settings", SettingsController, :show
    match :*, "/*path", NotFoundController, :show
  end

  scope "/", VisionApiWeb do
    get "/*path", DashboardController, :index
  end
end
