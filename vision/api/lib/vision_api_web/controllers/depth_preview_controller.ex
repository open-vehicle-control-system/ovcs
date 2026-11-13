defmodule VisionApiWeb.DepthPreviewController do
  @moduledoc """
  The depth video's colour range (`VisionCore.Preview`), a `depth-previews`
  singleton: `PATCH` sets `colourRangeM`, read from the JSON body only.
  The range is a view setting of the unit, shared by every dashboard and
  not saved. Both actions answer 503 while the previews do not run.
  """
  use VisionApiWeb, :controller

  alias VisionApiWeb.JsonApi
  alias VisionCore.Preview

  @range_pointer "/data/attributes/colourRangeM"

  def show(conn, _params) do
    case preview(&Preview.options/0) do
      {:ok, options} -> render(conn, :show, options: options)
      :not_running -> not_running(conn)
    end
  end

  def update(conn, _params) do
    data = JsonApi.document(conn)["data"]

    with :ok <- JsonApi.check_identity(data, "depth-previews", "current"),
         {:ok, range} <- fetch_range(data) do
      case preview(fn -> Preview.set_options(depth_range_m: range) end) do
        {:ok, {:ok, options}} ->
          render(conn, :show, options: options)

        {:ok, {:error, reason}} ->
          JsonApi.error(conn, 422, "Invalid value", reason, @range_pointer)

        :not_running ->
          not_running(conn)
      end
    else
      {:error, status, title, detail, pointer} ->
        JsonApi.error(conn, status, title, detail, pointer)
    end
  end

  defp fetch_range(%{"attributes" => %{"colourRangeM" => range}}), do: {:ok, range}

  defp fetch_range(_data),
    do: {:error, 400, "Bad Request", "data.attributes.colourRangeM is required", @range_pointer}

  defp preview(call) do
    {:ok, call.()}
  catch
    :exit, _reason -> :not_running
  end

  defp not_running(conn),
    do: JsonApi.error(conn, 503, "Previews not running", "the unit's previews do not run")
end
