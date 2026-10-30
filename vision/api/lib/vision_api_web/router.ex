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
    get "/stages", StageController, :index
    get "/parameters", ParameterController, :index
    get "/parameters/:id", ParameterController, :show
    patch "/parameters/:id", ParameterController, :update
    post "/parameter-saves", ParameterActionController, :save
    post "/parameter-discards", ParameterActionController, :discard
    post "/parameter-resets", ParameterActionController, :reset
    get "/composer-snippet", ComposerSnippetController, :show
    get "/configuration", ConfigurationController, :show
    get "/ros2-node", Ros2NodeController, :show
  end

  scope "/api", VisionApiWeb do
    pipe_through :api
    match :*, "/*path", NotFoundController, :show
  end

  scope "/", VisionApiWeb do
    get "/*path", DashboardController, :index
  end
end
