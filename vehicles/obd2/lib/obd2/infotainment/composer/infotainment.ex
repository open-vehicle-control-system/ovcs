defmodule Obd2.Infotainment.Composer.Infotainment do
  alias Obd2.Infotainment.Composer.Infotainment

  @grid_columns 24
  @grid_rows 8

  def infotainment_configuration do
    pages = %{
      "dashboard" => Infotainment.DashboardPage.definition(order: 0),
      "settings" => Infotainment.SettingsPage.definition(order: 1)
    }

    validate_pages!(pages)

    %{
      vehicle: %{
        name: "OBD2",
        main_color: "gray",
        refresh_interval: 50,
        grid_columns: @grid_columns,
        grid_rows: @grid_rows,
        background_image: "assets/images/launchpad_background.png",
        sidebar: %{
          width: 100,
          background_color: "CC1F2937"
        },
        block_style: %{
          background_color: "D9111827",
          border_radius: 30,
          padding: 20,
          margin: 10
        },
        pages: pages
      }
    }
  end

  defp validate_pages!(pages) do
    Enum.each(pages, fn {page_id, page} ->
      InfotainmentCore.LayoutValidator.validate!(
        page_id,
        page.blocks,
        @grid_columns,
        @grid_rows
      )
    end)
  end
end
