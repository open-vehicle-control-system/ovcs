defmodule VisionApiWeb.ErrorJSON do
  @moduledoc "Error responses: the status message of the error's status code."

  def render(template, _assigns) do
    %{errors: %{detail: Phoenix.Controller.status_message_from_template(template)}}
  end
end
