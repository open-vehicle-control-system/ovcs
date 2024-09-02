defmodule VmsApiWeb.Router do
  use VmsApiWeb, :router

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/api", VmsApiWeb.Api do
    pipe_through :api
    resources "/throttle-calibration", ThrottleCalibrationController, only: [:create, :show], singleton: true
  end

  # Enable LiveDashboard in development
  if Application.compile_env(:vms_api, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through [:fetch_session, :protect_from_forgery]

      live_dashboard "/dashboard", metrics: VmsApiWeb.Telemetry
    end
  end

  scope "/", VmsApiWeb do
    get "/*path", HomeController, :index
  end
end
