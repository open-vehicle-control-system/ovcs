defmodule InfotainmentApiWeb.Api.VolumeController do
  use InfotainmentApiWeb, :controller

  def post(conn, _params) do
    conn
    |> put_resp_header("content-type", "application/json; charset=utf-8")
    |> send_resp(200, '{"status":"ok"}')
  end

  def show(conn, _params) do
    volume = :os.cmd('amixer -c 1 get Master |grep % |awk \'{print $4}\'|sed \'s/[^0-9\%]//g\'')
    conn |> put_resp_header("content-type", "application/json; charset=utf-8")
    |> send_resp(200, '{"status":"ok", "volume": "#{volume}"}')
  end
end
