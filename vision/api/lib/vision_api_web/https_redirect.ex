defmodule VisionApiWeb.HttpsRedirect do
  @moduledoc """
  Answers every plain HTTP request with a redirect to the same path and
  query over HTTPS, on the endpoint's port (`https_port:`), left out when
  it is 443, and under the host the request was sent to, a name or an
  address. A GET or HEAD gets a 301, any other method a 307, which keeps
  the method and body. Sends no HSTS header: it would hold the host to
  HTTPS on every port.
  """
  @behaviour Plug

  import Plug.Conn

  @impl Plug
  def init(options), do: Keyword.validate!(options, [:https_port])

  @impl Plug
  def call(conn, options) do
    location =
      "https://#{conn.host}#{port(options[:https_port])}#{conn.request_path}#{query(conn)}"

    conn
    |> put_resp_header("location", location)
    |> send_resp(status(conn.method), "")
    |> halt()
  end

  defp port(443), do: ""
  defp port(port), do: ":#{port}"

  defp query(%{query_string: ""}), do: ""
  defp query(%{query_string: query_string}), do: "?" <> query_string

  defp status(method) when method in ["GET", "HEAD"], do: 301
  defp status(_method), do: 307
end
