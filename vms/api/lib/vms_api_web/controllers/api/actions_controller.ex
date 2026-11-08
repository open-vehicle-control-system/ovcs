defmodule VmsApiWeb.Api.ActionsController do
  @moduledoc """
  `POST /api/actions`: runs an action row of the vehicle's dashboard.

  Only a `module` and `action` pair that an action row of the composer's
  `dashboard_configuration/0` declares, on a module exporting
  `trigger_action/2`, is called; any other request answers `404`. The
  request's strings are compared with the declared rows, so no atom is
  created from them.
  """
  use VmsApiWeb, :controller

  def create(conn, params) do
    case declared_action_module(params["module"], params["action"]) do
      nil ->
        conn
        |> put_status(:not_found)
        |> put_view(json: VmsApiWeb.ErrorJSON)
        |> render(:"404")

      module ->
        trigger_action(conn, module, params)
    end
  end

  defp trigger_action(conn, module, params) do
    case module.trigger_action(params["action"], params) do
      :ok ->
        conn
        |> put_status(:created)
        |> text("")

      {:error, reason} ->
        conn
        |> put_status(:unprocessable_entity)
        |> put_view(json: VmsApiWeb.ErrorJSON)
        |> render(:"422", reason: reason)
    end
  end

  defp declared_action_module(module_name, action)
       when is_binary(module_name) and is_binary(action) do
    VmsCore.Application.vehicle_composer()
    |> dashboard_action_rows()
    |> Enum.find_value(&callable_module(&1, module_name, action))
  end

  defp declared_action_module(_module_name, _action), do: nil

  defp callable_module(%{module: module, action: action}, module_name, action) do
    if Atom.to_string(module) == module_name and exports?(module, :trigger_action, 2),
      do: module
  end

  defp callable_module(_row, _module_name, _action), do: nil

  defp dashboard_action_rows(composer) do
    if exports?(composer, :dashboard_configuration, 0) do
      for {_page_id, page} <- composer.dashboard_configuration().vehicle.pages,
          {_block_id, block} <- page.blocks,
          row <- Map.get(block, :rows, []),
          row.type == :action,
          do: row
    else
      []
    end
  end

  defp exports?(module, function, arity) do
    Code.ensure_loaded?(module) and function_exported?(module, function, arity)
  end
end
