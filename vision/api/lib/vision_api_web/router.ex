defmodule VisionApiWeb.Router do
  use VisionApiWeb, :router

  import VisionApiWeb.JsonApi, only: [put_media_type: 2]

  pipeline :jsonapi do
    plug :accepts, ["jsonapi", "json"]
    plug :put_media_type
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
    get "/configuration", ConfigurationController, :show
    get "/firmware", FirmwareController, :show
    get "/ros2-node", Ros2NodeController, :show
  end

  scope "/api", VisionApiWeb do
    match :*, "/*path", NotFoundController, :show
  end

  scope "/", VisionApiWeb do
    get "/*path", DashboardController, :index
  end
end
