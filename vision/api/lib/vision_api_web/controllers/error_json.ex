defmodule VisionApiWeb.ErrorJSON do
  @moduledoc """
  The body of an error raised outside the controllers: a JSON:API error
  object with the status code and its status message, and for a fault of
  the request, a 4xx, a `detail` saying what is wrong with it.
  """

  @doc "The error document for `template`, such as `\"500.json\"`, and the `:reason` raised."
  @spec render(String.t(), map()) :: map()
  def render(template, assigns) do
    [status | _format] = String.split(template, ".")
    error = %{status: status, title: Phoenix.Controller.status_message_from_template(template)}

    case assigns do
      %{reason: reason} when status < "500" ->
        %{errors: [Map.put(error, :detail, detail(reason))]}

      _assigns ->
        %{errors: [error]}
    end
  end

  defp detail(%Phoenix.NotAcceptableError{}),
    do: "the answer is application/vnd.api+json, which the Accept header refuses"

  defp detail(reason) when is_exception(reason), do: Exception.message(reason)
  defp detail(_reason), do: "the request cannot be answered"
end
