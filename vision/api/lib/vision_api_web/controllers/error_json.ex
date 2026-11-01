defmodule VisionApiWeb.ErrorJSON do
  @moduledoc """
  The body of an error raised outside the controllers, such as a 500: a
  JSON:API error object with the status code and its status message.
  """

  @doc "The error document for `template`, such as `\"500.json\"`."
  @spec render(String.t(), map()) :: map()
  def render(template, _assigns) do
    [status | _format] = String.split(template, ".")

    %{
      errors: [
        %{status: status, title: Phoenix.Controller.status_message_from_template(template)}
      ]
    }
  end
end
