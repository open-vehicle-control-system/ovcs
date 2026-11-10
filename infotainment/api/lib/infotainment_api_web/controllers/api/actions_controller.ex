defmodule InfotainmentApiWeb.Api.ActionsController do
  @moduledoc """
  `POST /api/actions`: runs an action of the vehicle's infotainment pages.

  Only a `module` and `action` pair that a block's `actions` in the
  composer's `infotainment_configuration/0` declares, on a module
  exporting `trigger_action/2`, is called; any other request answers
  `404`. The request's strings are compared with the declared actions,
  so no atom is created from them.
  """
  use InfotainmentApiWeb, :controller

  def create(conn, params) do
    case declared_action_module(params["module"], params["action"]) do
      nil ->
        conn
        |> put_status(:not_found)
        |> put_view(json: InfotainmentApiWeb.ErrorJSON)
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
        |> put_view(json: InfotainmentApiWeb.ErrorJSON)
        |> render(:"422", reason: reason)
    end
  end

  defp declared_action_module(module_name, action)
       when is_binary(module_name) and is_binary(action) do
    InfotainmentCore.Application.vehicle_composer()
    |> declared_actions()
    |> Enum.find_value(&callable_module(&1, module_name, action))
  end

  defp declared_action_module(_module_name, _action), do: nil

  defp callable_module(%{module: module, action: action}, module_name, action) do
    if Atom.to_string(module) == module_name and exports?(module, :trigger_action, 2),
      do: module
  end

  defp callable_module(_declared, _module_name, _action), do: nil

  defp declared_actions(composer) do
    if exports?(composer, :infotainment_configuration, 0) do
      for {_page_id, page} <- composer.infotainment_configuration().vehicle.pages,
          {_block_id, block} <- page.blocks,
          declared <- Map.get(block, :actions, []),
          do: declared
    else
      []
    end
  end

  defp exports?(module, function, arity) do
    Code.ensure_loaded?(module) and function_exported?(module, function, arity)
  end
end
