defmodule InfotainmentApiWeb.SystemInformationChannel do
  use Phoenix.Channel
  require Logger

  alias InfotainmentCore.SystemInformationManager

  intercept ["update"]

  def join("system-information", _message, socket) do
    Logger.debug("System Information channel connected")
    send(self(), :init)
    {:ok, socket}
  end

  def handle_info(:init, socket) do
    Logger.debug("Channel initialized")
    data = SystemInformationManager.information()
    push(socket, "updated", render_system_information(data))
    {:noreply, socket}
  end

  def handle_out("update", information, socket) do
    Logger.debug("Channel will output event")
    push(socket, "updated", render_system_information(information))
    {:noreply, socket}
  end

  defp render_system_information(data) do
    %{
      data: data  |> Map.values() |> Enum.map(fn(data_point) ->
        render_data_point(data_point)
      end)
    }
  end

  defp render_data_point(data_point) do
    %{
      id: data_point.name,
      type: "system",
      attributes: %{
        name: data_point.name,
        value: data_point.value,
        unit: data_point.unit
      }
    }
  end
end
