defmodule OvcsBusGateway.Http.EndpointTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest

  alias OvcsBusGateway.Cache

  @endpoint OvcsBusGateway.Http.Endpoint

  setup_all do
    {:ok, _apps} = Application.ensure_all_started(:phoenix)
    :ok
  end

  setup do
    start_supervised!(Cache)
    start_supervised!({OvcsBusGateway.Http, port: 0})
    :ok
  end

  test "answers HEAD as GET, without the body" do
    conn = head(build_conn(), "/api/signals")

    assert conn.status == 200
    assert conn.resp_body == ""
  end

  test "answers a request no route takes with a JSON:API error" do
    conn = post(build_conn(), "/")

    assert conn.status == 404

    assert Jason.decode!(conn.resp_body) == %{
             "errors" => [%{"status" => "404", "title" => "Not Found"}]
           }
  end
end
