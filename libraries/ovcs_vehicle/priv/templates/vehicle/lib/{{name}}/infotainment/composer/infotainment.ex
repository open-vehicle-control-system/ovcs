defmodule <%= @module %>.Infotainment.Composer.Infotainment do
  @moduledoc """
  Infotainment UI layout — one or more pages, each with a grid of
  blocks. The scaffold ships a single dashboard page with a single
  status block; extend by adding more pages and blocks (see the
  `Blocks.*` modules for examples).
  """
  alias <%= @module %>.Infotainment.Composer.Infotainment

  @grid_columns 24
  @grid_rows 8

  def infotainment_configuration do
    pages = %{
      "dashboard" => Infotainment.DashboardPage.definition(order: 0)
    }

    validate_pages!(pages)

    %{
      vehicle: %{
        name: "<%= @display_name %>",
        main_color: "gray",
        refresh_interval: 50,
        grid_columns: @grid_columns,
        grid_rows: @grid_rows,
        sidebar: %{width: 100, background_color: "CC1F2937"},
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
      InfotainmentCore.LayoutValidator.validate!(page_id, page.blocks, @grid_columns, @grid_rows)
    end)
  end
end
