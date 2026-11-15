defmodule VisionApiWeb.Router do
  use VisionApiWeb, :router

  import VisionApiWeb.JsonApi, only: [check_path: 2, check_query: 2, put_media_type: 2]

  pipeline :jsonapi_media_type do
    plug :put_media_type
  end

  # After `:jsonapi_media_type`, a pipeline of its own: an error raised here, a refused `Accept` or a body that is not JSON, is rendered on the conn this pipeline was given.
  pipeline :jsonapi do
    plug :check_path
    plug :check_query
    plug :accepts, ["jsonapi", "json"]
    plug Plug.Parsers, parsers: [:json], pass: ["*/*"], json_decoder: Phoenix.json_library()
  end

  scope "/api", VisionApiWeb do
    pipe_through [:jsonapi_media_type, :jsonapi]
    get "/stages", StageController, :index, private: %{jsonapi_include: true}
    get "/parameters", ParameterController, :index
    get "/parameters/:id", ParameterController, :show
    patch "/parameters/:id", ParameterController, :update
    post "/parameter-saves", ParameterSaveController, :create
    post "/parameter-discards", ParameterDiscardController, :create
    post "/parameter-resets", ParameterResetController, :create
    get "/depth-preview", DepthPreviewController, :show
    patch "/depth-preview", DepthPreviewController, :update
    get "/configuration", ConfigurationController, :show
    get "/firmware", FirmwareController, :show
    get "/board", BoardController, :show
    get "/exporters", ExporterController, :index
    post "/exporters/:id/actions/:name", ExporterActionController, :create
    get "/ros2-node", Ros2NodeController, :show, private: %{jsonapi_include: true}
    get "/calibrations", CalibrationController, :index
    get "/calibrations/:id", CalibrationController, :show
    post "/calibration-sessions", CalibrationSessionController, :create
    post "/calibration-cancels", CalibrationCancelController, :create
    post "/calibration-solves", CalibrationSolveController, :create
    post "/calibration-applies", CalibrationApplyController, :create
    post "/calibration-resets", CalibrationResetController, :create
    get "/saved-calibrations", SavedCalibrationController, :index
    get "/saved-calibrations/:id", SavedCalibrationController, :show
    patch "/saved-calibrations/:id", SavedCalibrationController, :update
    delete "/saved-calibrations/:id", SavedCalibrationController, :delete
    get "/recordings", RecordingController, :index, private: %{jsonapi_include: true}
    get "/recordings/:id", RecordingController, :show, private: %{jsonapi_include: true}
    post "/recordings", RecordingController, :create
    patch "/recordings/:id", RecordingController, :update
    delete "/recordings/:id", RecordingController, :delete
    get "/recordings/:id/download", RecordingDownloadController, :show
    get "/disks", DiskController, :index
    patch "/disks/:id", DiskController, :update
    post "/disk-ejects", DiskEjectController, :create
    post "/disk-formats", DiskFormatController, :create
  end

  scope "/api", VisionApiWeb do
    match :*, "/*path", NotFoundController, :show
  end

  scope "/", VisionApiWeb do
    get "/*path", DashboardController, :index
  end
end
