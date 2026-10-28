defmodule VisionApiWeb.Router do
  use VisionApiWeb, :router

  pipeline :api do
    plug :accepts, ["json"]
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
