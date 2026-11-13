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

  @doc "The request's document: its JSON body, `%{}` for a body that is not JSON."
  @spec document(Plug.Conn.t()) :: map()
  def document(%Plug.Conn{body_params: %Plug.Conn.Unfetched{}}), do: %{}
  def document(%Plug.Conn{body_params: document}), do: document

  @doc """
  Checks that `data`, a write's resource object, is the resource of `type`
  and `id` its route names: `:ok`, or the refusal `error/5` sends, a 409
  for another `type` or `id` and a 400 for a missing one.
  """
  @spec check_identity(term(), String.t(), String.t()) ::
          :ok | {:error, pos_integer(), String.t(), String.t(), String.t()}
  def check_identity(%{"type" => type}, expected, _id) when type != expected,
    do: {:error, 409, "Conflict", "type must be #{expected}", "/data/type"}

  def check_identity(%{"id" => id}, _type, expected) when id != expected,
    do: {:error, 409, "Conflict", "id must be #{expected}", "/data/id"}

  def check_identity(%{"type" => _type, "id" => _id}, _expected_type, _expected_id), do: :ok

  def check_identity(%{"type" => _type}, _expected_type, _expected_id),
    do: {:error, 400, "Bad Request", "data.id is required", "/data/id"}

  def check_identity(%{}, _expected_type, _expected_id),
    do: {:error, 400, "Bad Request", "data.type is required", "/data/type"}

  def check_identity(_data, _type, _id),
    do: {:error, 400, "Bad Request", "data is required", "/data"}

  @doc "The refusal `error/5` sends for a created resource whose document carries an id of the client's."
  @spec client_id_refusal() :: {:error, 403, String.t(), String.t(), String.t()}
  def client_id_refusal,
    do: {:error, 403, "Forbidden", "the unit names the resource: send no id", "/data/id"}

  @doc """
  The relationships the `include` query parameter of `params` names, each
  once; `:error` for one that is not among `supported`, and for an
  `include` that is not text.
  """
  @spec includes(map(), [String.t()]) :: {:ok, [String.t()]} | :error
  def includes(%{"include" => include}, supported) when is_binary(include) do
    includes = include |> String.split(",", trim: true) |> Enum.uniq()
    if Enum.all?(includes, &(&1 in supported)), do: {:ok, includes}, else: :error
  end

  def includes(%{"include" => _include}, _supported), do: :error
  def includes(_params, _supported), do: {:ok, []}

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
