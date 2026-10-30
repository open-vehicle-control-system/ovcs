defmodule VisionApiWeb.JsonApi do
  @moduledoc "JSON:API 1.1 responses: the media type and the error objects."
  import Plug.Conn

  @media_type "application/vnd.api+json"

  @doc "Sends `document` as JSON with the JSON:API media type."
  @spec send_document(Plug.Conn.t(), pos_integer(), map()) :: Plug.Conn.t()
  def send_document(conn, status, document) do
    conn
    |> put_resp_content_type(@media_type, nil)
    |> send_resp(status, Jason.encode!(document))
  end

  @doc "Sends an error object; `source` is a JSON pointer, or a map such as `%{parameter: \"include\"}`."
  @spec error(Plug.Conn.t(), pos_integer(), String.t(), String.t(), map() | String.t() | nil) ::
          Plug.Conn.t()
  def error(conn, status, title, detail, source \\ nil) do
    error = %{status: Integer.to_string(status), title: title, detail: detail}
    error = if source, do: Map.put(error, :source, source(source)), else: error
    send_document(conn, status, %{errors: [error]})
  end

  defp source(pointer) when is_binary(pointer), do: %{pointer: pointer}
  defp source(source) when is_map(source), do: source

  @doc "A resource object."
  @spec resource(String.t(), String.t(), map(), map()) :: map()
  def resource(type, id, attributes, relationships \\ %{}) do
    %{type: type, id: id, attributes: attributes, relationships: relationships}
  end

  @doc "The resource object of a created action, listing the parameters it touched."
  @spec action(String.t(), String.t(), [String.t()]) :: map()
  def action(type, id, parameters),
    do: %{type: type, id: id, attributes: %{parameters: parameters}}
end
