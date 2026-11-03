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

  @doc """
  Answers a 400 naming the first of `conn`'s query parameters that `allowed` does not list, or
  returns `:ok` when there is none.
  """
  @spec check_parameters(Plug.Conn.t(), [String.t()]) :: :ok | Plug.Conn.t()
  def check_parameters(conn, allowed) do
    case conn.query_params |> Map.keys() |> Enum.sort() |> Enum.reject(&(&1 in allowed)) do
      [] -> :ok
      [parameter | _others] -> unsupported_parameter(conn, parameter)
    end
  end

  @doc "Answers a 400 naming `parameter`, a query parameter the route does not take."
  @spec unsupported_parameter(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  def unsupported_parameter(conn, parameter) do
    detail = "unsupported query parameter #{parameter}"
    error(conn, 400, "Bad Request", detail, %{parameter: parameter})
  end

  @doc "A resource object, without `relationships` when it has none."
  @spec resource(String.t(), String.t(), map(), map()) :: map()
  def resource(type, id, attributes, relationships \\ %{})

  def resource(type, id, attributes, relationships) when relationships == %{},
    do: %{type: type, id: id, attributes: attributes}

  def resource(type, id, attributes, relationships),
    do: %{type: type, id: id, attributes: attributes, relationships: relationships}

  @doc "A to-one relationship."
  @spec to_one(String.t(), String.t()) :: map()
  def to_one(type, id), do: %{data: %{type: type, id: id}}

  @doc "A to-many relationship."
  @spec to_many(String.t(), [String.t()]) :: map()
  def to_many(type, ids), do: %{data: Enum.map(ids, &%{type: type, id: &1})}
end
