defmodule VisionApiWeb.JsonApi do
  @moduledoc "JSON:API 1.1 responses: the media type and the error objects."
  import Plug.Conn

  @media_type "application/vnd.api+json"

  @doc "Sends `document` as JSON with the JSON:API media type."
  @spec send_document(Plug.Conn.t(), pos_integer(), map()) :: Plug.Conn.t()
  def send_document(conn, status, document) do
    conn
    |> put_resp_content_type(@media_type)
    |> send_resp(status, Jason.encode!(document))
  end

  @doc "Sends an error object; `pointer` is the JSON pointer of the offending member."
  @spec error(Plug.Conn.t(), pos_integer(), String.t(), String.t(), String.t() | nil) ::
          Plug.Conn.t()
  def error(conn, status, title, detail, pointer \\ nil) do
    error = %{status: Integer.to_string(status), title: title, detail: detail}
    error = if pointer, do: Map.put(error, :source, %{pointer: pointer}), else: error
    send_document(conn, status, %{errors: [error]})
  end

  @doc "A resource object."
  @spec resource(String.t(), String.t(), map(), map()) :: map()
  def resource(type, id, attributes, relationships \\ %{}) do
    %{type: type, id: id, attributes: attributes, relationships: relationships}
  end
end
