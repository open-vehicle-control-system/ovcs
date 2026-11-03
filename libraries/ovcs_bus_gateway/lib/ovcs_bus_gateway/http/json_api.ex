defmodule OvcsBusGateway.Http.JsonApi do
  @moduledoc "JSON:API 1.1 responses: the media type, the error objects and the resource objects."

  import Plug.Conn

  @media_type "application/vnd.api+json"

  @doc """
  Plug putting the JSON:API media type on the response, without the `charset` parameter
  JSON:API forbids. `Phoenix.Controller.json/2` keeps a content type already set.
  """
  @spec put_media_type(Plug.Conn.t(), term()) :: Plug.Conn.t()
  def put_media_type(conn, _opts), do: put_resp_content_type(conn, @media_type, nil)

  @doc """
  Sends a document holding one error object; `source` names what is at fault, such as
  `%{parameter: "filter[unit]"}`.
  """
  @spec error(Plug.Conn.t(), pos_integer(), String.t(), String.t(), map() | nil) :: Plug.Conn.t()
  def error(conn, status, title, detail, source \\ nil) do
    error = %{status: Integer.to_string(status), title: title, detail: detail}
    error = if source, do: Map.put(error, :source, source), else: error

    conn
    |> put_media_type([])
    |> send_resp(status, Jason.encode!(%{errors: [error]}))
  end

  @doc "A resource object."
  @spec resource(String.t(), String.t(), map()) :: map()
  def resource(type, id, attributes), do: %{type: type, id: id, attributes: attributes}
end
