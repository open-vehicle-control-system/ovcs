defmodule VisionApiWeb.HttpsRedirectTest do
  use ExUnit.Case, async: true

  import Plug.Conn
  import Plug.Test

  alias VisionApiWeb.HttpsRedirect

  @options HttpsRedirect.init(https_port: 4100)

  test "redirects a GET to the same path and query on the HTTPS port, under the host it was sent to" do
    conn =
      conn(:get, "http://unit-vision.local/api/parameters?include=stage")
      |> HttpsRedirect.call(@options)

    assert conn.status == 301

    assert get_resp_header(conn, "location") == [
             "https://unit-vision.local:4100/api/parameters?include=stage"
           ]
  end

  test "redirects a request by IP address to that address" do
    conn = conn(:get, "http://192.0.2.10/") |> HttpsRedirect.call(@options)

    assert get_resp_header(conn, "location") == ["https://192.0.2.10:4100/"]
  end

  test "redirects a write with its method kept" do
    conn =
      conn(:post, "http://unit-vision.local/api/parameter-saves") |> HttpsRedirect.call(@options)

    assert conn.status == 307

    assert get_resp_header(conn, "location") == [
             "https://unit-vision.local:4100/api/parameter-saves"
           ]
  end

  test "leaves the port out on HTTPS's own, 443" do
    options = HttpsRedirect.init(https_port: 443)

    conn = conn(:get, "http://unit-vision.local:4100/api/firmware") |> HttpsRedirect.call(options)

    assert get_resp_header(conn, "location") == ["https://unit-vision.local/api/firmware"]
  end

  test "tells no browser to keep to HTTPS" do
    conn = conn(:get, "http://unit-vision.local/") |> HttpsRedirect.call(@options)

    assert get_resp_header(conn, "strict-transport-security") == []
  end

  describe "listeners/2" do
    test "listens for plain HTTP on each port, redirecting to the endpoint's HTTPS port" do
      assert [
               %{id: {:https_redirect, 80}, start: {Bandit, :start_link, [port_80]}},
               %{id: {:https_redirect, 4100}, start: {Bandit, :start_link, [port_4100]}}
             ] = HttpsRedirect.listeners([port: 443], [80, 4100])

      assert port_80[:port] == 80
      assert port_4100[:port] == 4100
      assert port_80[:scheme] == :http
      assert port_80[:plug] == {HttpsRedirect, https_port: 443}
    end

    test "listens on no port for an endpoint without HTTPS" do
      assert HttpsRedirect.listeners(nil, [80, 4100]) == []
    end
  end
end
