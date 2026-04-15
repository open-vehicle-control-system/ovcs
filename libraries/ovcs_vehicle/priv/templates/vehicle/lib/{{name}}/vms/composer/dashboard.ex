defmodule <%= @module %>.Vms.Composer.Dashboard do
  @moduledoc """
  VMS dashboard layout — a list of pages shown by the VMS dashboard
  app. The scaffold ships a single "status" page with a single block;
  add pages and blocks per feature your vehicle gains.
  """
  alias <%= @module %>.Vms.Composer.Dashboard

  def dashboard_configuration do
    %{
      vehicle: %{
        name: "<%= @upper %>",
        main_color: "blue",
        refresh_interval: 100,
        pages: %{
          "status" => Dashboard.DashboardPage.definition(order: 0)
        }
      }
    }
  end
end
