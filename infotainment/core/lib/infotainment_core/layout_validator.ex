defmodule InfotainmentCore.LayoutValidator do
  @moduledoc """
  Validates that blocks in a page definition do not overlap on the grid.

  Each block must define `column`, `row`, `columns`, and `rows`.
  Blocks are placed on a grid where `column` and `row` are 0-indexed
  starting positions, and `columns`/`rows` are the span.

  This module is meant to be called at configuration time (e.g., in the
  composer) to catch layout errors early.
  """

  @doc """
  Validates that no two blocks in a page overlap. Raises if they do.

  ## Parameters
    - `page_name` - the page identifier (for error messages)
    - `blocks` - a map of block_id => block definition maps, each with
      `:column`, `:row`, `:columns`, `:rows` keys
    - `grid_columns` - total number of grid columns
    - `grid_rows` - total number of grid rows
  """
  def validate!(page_name, blocks, grid_columns, grid_rows) do
    block_list = Enum.map(blocks, fn {id, block} -> {id, block} end)

    # Check bounds
    Enum.each(block_list, fn {id, block} ->
      if block.column + block.columns > grid_columns do
        raise "Block '#{id}' on page '#{page_name}' exceeds grid width: " <>
                "column #{block.column} + span #{block.columns} > #{grid_columns} columns"
      end

      if block.row + block.rows > grid_rows do
        raise "Block '#{id}' on page '#{page_name}' exceeds grid height: " <>
                "row #{block.row} + span #{block.rows} > #{grid_rows} rows"
      end
    end)

    # Check pairwise overlaps
    for {id_a, a} <- block_list,
        {id_b, b} <- block_list,
        id_a < id_b do
      if overlaps?(a, b) do
        raise "Blocks '#{id_a}' and '#{id_b}' overlap on page '#{page_name}': " <>
                "'#{id_a}' at (#{a.column},#{a.row}) spanning #{a.columns}x#{a.rows}, " <>
                "'#{id_b}' at (#{b.column},#{b.row}) spanning #{b.columns}x#{b.rows}"
      end
    end

    :ok
  end

  defp overlaps?(a, b) do
    a_left = a.column
    a_right = a.column + a.columns
    a_top = a.row
    a_bottom = a.row + a.rows

    b_left = b.column
    b_right = b.column + b.columns
    b_top = b.row
    b_bottom = b.row + b.rows

    a_left < b_right and a_right > b_left and
      a_top < b_bottom and a_bottom > b_top
  end
end
