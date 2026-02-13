defmodule InfotainmentApiWeb.Api.VehicleJSON do
  use InfotainmentApiWeb, :view

  def render("show.json", %{vehicle: vehicle}) do
    %{
      data: render_one(vehicle, __MODULE__, "vehicle.json", as: :vehicle)
    }
  end

  def render("vehicle.json", %{vehicle: vehicle}) do
    %{
      type: "vehicle",
      id: "vehicle",
      attributes: %{
        name: vehicle.name,
        refreshInterval: vehicle.refresh_interval,
        mainColor: vehicle.main_color,
        gridColumns: vehicle.grid_columns,
        gridRows: vehicle.grid_rows,
        backgroundImage: vehicle[:background_image],
        sidebar: render_sidebar(vehicle[:sidebar]),
        blockStyle: render_block_style(vehicle[:block_style])
      }
    }
  end

  defp render_sidebar(nil), do: nil

  defp render_sidebar(sidebar) do
    %{
      width: sidebar[:width],
      backgroundColor: sidebar[:background_color]
    }
  end

  defp render_block_style(nil), do: nil

  defp render_block_style(style) do
    %{
      backgroundColor: style[:background_color],
      borderRadius: style[:border_radius],
      padding: style[:padding],
      margin: style[:margin]
    }
  end
end
