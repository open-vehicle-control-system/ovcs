defmodule VisionApiWeb.JsonApi do
  @moduledoc "JSON:API 1.1 responses: the media type, the error objects and the resource objects the `*JSON` modules build."
  import Plug.Conn

  @media_type "application/vnd.api+json"

  @typedoc "A refusal for `error/4`: the status, the detail and its options."
  @type refusal :: {:error, pos_integer(), String.t(), keyword()}

  @doc """
  Plug putting the JSON:API media type on the response, without the
  `charset` parameter JSON:API forbids. `render/3` keeps a content type
  already set.
  """
  @spec put_media_type(Plug.Conn.t(), term()) :: Plug.Conn.t()
  def put_media_type(conn, _opts), do: put_resp_content_type(conn, @media_type, nil)

  @doc """
  Plug answering a 400 to a request whose path parameters are not all
  valid UTF-8: such a text cannot be looked up, nor put in a JSON answer.
  """
  @spec check_path(Plug.Conn.t(), term()) :: Plug.Conn.t()
  def check_path(conn, _opts) do
    if Enum.all?(conn.path_params, fn {_name, value} -> valid_text?(value) end),
      do: conn,
      else: conn |> error(400, "the path is not valid UTF-8") |> halt()
  end

  @doc """
  Plug answering a 400 to a query parameter of JSON:API the route does
  not support: `sort`, and `include` on a route without
  `private: %{jsonapi_include: true}`.
  """
  @spec check_query(Plug.Conn.t(), term()) :: Plug.Conn.t()
  def check_query(conn, _opts) do
    conn = fetch_query_params(conn)
    supported = if conn.private[:jsonapi_include], do: ["include"], else: []

    case Enum.find(["include", "sort"] -- supported, &is_map_key(conn.query_params, &1)) do
      nil ->
        conn

      parameter ->
        conn
        |> error(400, "#{parameter} is not supported on this route",
          source: %{parameter: parameter}
        )
        |> halt()
    end
  end

  defp valid_text?(value) when is_binary(value), do: String.valid?(value)
  defp valid_text?(values) when is_list(values), do: Enum.all?(values, &valid_text?/1)

  @doc "The request's document: its JSON body, `%{}` for a body that is not JSON."
  @spec document(Plug.Conn.t()) :: map()
  def document(%Plug.Conn{body_params: %Plug.Conn.Unfetched{}}), do: %{}
  def document(%Plug.Conn{body_params: document}), do: document

  @doc """
  Checks that `data`, a write's resource object, is the resource of `type`
  and `id` its route names: `:ok`, or the refusal `error/4` sends, a 409
  for another `type` or `id` and a 400 for a missing one.
  """
  @spec check_identity(term(), String.t(), String.t()) :: :ok | refusal()
  def check_identity(%{"type" => type}, expected, _id) when type != expected,
    do: {:error, 409, "type must be #{expected}", [source: "/data/type"]}

  def check_identity(%{"id" => id}, _type, expected) when id != expected,
    do: {:error, 409, "id must be #{expected}", [source: "/data/id"]}

  def check_identity(%{"type" => _type, "id" => _id}, _expected_type, _expected_id), do: :ok

  def check_identity(%{"type" => _type}, _expected_type, _expected_id),
    do: {:error, 400, "data.id is required", [source: "/data/id"]}

  def check_identity(%{}, _expected_type, _expected_id),
    do: {:error, 400, "data.type is required", [source: "/data/type"]}

  def check_identity(_data, _type, _id),
    do: {:error, 400, "data is required", [source: "/data"]}

  @doc """
  The resource object of `document`, a write creating a resource of
  `type` that the unit names: `{:ok, data}`, or the refusal `refuse/2`
  sends, a 403 for an id of the client's, a 409 for another `type` and a
  400 without one.
  """
  @spec fetch_created(term(), String.t()) :: {:ok, map()} | refusal()
  def fetch_created(%{"data" => %{"type" => type, "id" => _id}}, type), do: client_id_refusal()
  def fetch_created(%{"data" => %{"type" => type} = data}, type), do: {:ok, data}

  def fetch_created(%{"data" => %{"type" => _other}}, type),
    do: {:error, 409, "type must be #{type}", [source: "/data/type"]}

  def fetch_created(_document, _type),
    do: {:error, 400, "data with a type is required", [source: "/data"]}

  @doc "The attribute `name` of `data`, a write's resource object, or the 400 `refuse/2` sends without it."
  @spec fetch_attribute(term(), String.t()) :: {:ok, term()} | refusal()
  def fetch_attribute(%{"attributes" => %{} = attributes}, name)
      when is_map_key(attributes, name),
      do: {:ok, Map.fetch!(attributes, name)}

  def fetch_attribute(_data, name),
    do: {:error, 400, "data.attributes.#{name} is required", [source: "/data/attributes/#{name}"]}

  @doc "The id of a resource the unit creates for an action: unique while it runs."
  @spec action_id() :: String.t()
  def action_id, do: Integer.to_string(System.unique_integer([:positive, :monotonic]))

  @doc "The refusal `error/4` sends for a created resource whose document carries an id of the client's."
  @spec client_id_refusal() :: refusal()
  def client_id_refusal,
    do: {:error, 403, "the unit names the resource: send no id", [source: "/data/id"]}

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

  @doc """
  Sends an error object for `status`, saying why in `detail`. Options:
  `:source`, a JSON pointer, or a map such as `%{parameter: "include"}`,
  and `:title`, when it says more than the status's reason phrase.
  """
  @spec error(Plug.Conn.t(), pos_integer(), String.t(), keyword()) :: Plug.Conn.t()
  def error(conn, status, detail, options \\ []) do
    title = Keyword.get_lazy(options, :title, fn -> Plug.Conn.Status.reason_phrase(status) end)
    error = %{status: Integer.to_string(status), title: title, detail: detail}

    error =
      case Keyword.fetch(options, :source) do
        {:ok, source} -> Map.put(error, :source, source(source))
        :error -> error
      end

    conn
    |> put_media_type([])
    |> send_resp(status, Jason.encode!(%{errors: [error]}))
  end

  @doc "Sends the error object of `refusal`, as `error/4` does."
  @spec refuse(Plug.Conn.t(), refusal()) :: Plug.Conn.t()
  def refuse(conn, {:error, status, detail, options}), do: error(conn, status, detail, options)

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
