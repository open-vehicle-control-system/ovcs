defmodule VisionApiWeb.JsonApi do
  @moduledoc "JSON:API 1.1 responses: the media type, the error objects and the resource objects the `*JSON` modules build."
  import Plug.Conn

  @media_type "application/vnd.api+json"

  @doc """
  Plug putting the JSON:API media type on the response, without the
  `charset` parameter JSON:API forbids. `render/3` keeps a content type
  already set.
  """
  @spec put_media_type(Plug.Conn.t(), term()) :: Plug.Conn.t()
  def put_media_type(conn, _opts), do: put_resp_content_type(conn, @media_type, nil)

  @doc "Sends an error object; `source` is a JSON pointer, or a map such as `%{parameter: \"include\"}`."
  @spec error(Plug.Conn.t(), pos_integer(), String.t(), String.t(), map() | String.t() | nil) ::
          Plug.Conn.t()
  def error(conn, status, title, detail, source \\ nil) do
    error = %{status: Integer.to_string(status), title: title, detail: detail}
    error = if source, do: Map.put(error, :source, source(source)), else: error

    conn
    |> put_media_type([])
    |> send_resp(status, Jason.encode!(%{errors: [error]}))
  end

  defp source(pointer) when is_binary(pointer), do: %{pointer: pointer}
  defp source(source) when is_map(source), do: source

  @doc "A resource object, without `relationships` when it has none."
  @spec resource(String.t(), String.t(), map(), map()) :: map()
  def resource(type, id, attributes, relationships \\ %{})

  def resource(type, id, attributes, relationships) when relationships == %{},
    do: %{type: type, id: id, attributes: attributes}

  def resource(type, id, attributes, relationships),
    do: %{type: type, id: id, attributes: attributes, relationships: relationships}

  @doc "A to-one relationship; `id` is `nil` when there is none."
  @spec to_one(String.t(), String.t() | nil) :: map()
  def to_one(_type, nil), do: %{data: nil}
  def to_one(type, id), do: %{data: %{type: type, id: id}}

  @doc "A to-many relationship."
  @spec to_many(String.t(), [String.t()]) :: map()
  def to_many(type, ids), do: %{data: Enum.map(ids, &%{type: type, id: &1})}
end
