defmodule VisionApiWeb.ConnCase do
  @moduledoc "Test case for controller tests: a fresh `conn`, `Phoenix.ConnTest` and `post_document/3`."
  use ExUnit.CaseTemplate

  using do
    quote do
      @endpoint VisionApiWeb.Endpoint

      import Plug.Conn
      import Phoenix.ConnTest
      import VisionApiWeb.ConnCase, only: [post_document: 3]
    end
  end

  setup _tags do
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end

  @doc "Posts to `path` the JSON:API document whose resource object is `data`."
  @spec post_document(Plug.Conn.t(), String.t(), map()) :: Plug.Conn.t()
  def post_document(conn, path, data) do
    conn
    |> Plug.Conn.put_req_header("content-type", "application/vnd.api+json")
    |> Phoenix.ConnTest.dispatch(VisionApiWeb.Endpoint, :post, path, Jason.encode!(%{data: data}))
  end
end
