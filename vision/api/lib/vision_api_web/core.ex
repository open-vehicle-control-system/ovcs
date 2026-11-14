defmodule VisionApiWeb.Core do
  @moduledoc """
  Answers for the vision core while it cannot be asked: a call to one of
  its servers that is not running, is restarting or does not reply in
  time exits, and the request is answered a 503 instead of a 500.
  """
  require Logger

  alias VisionApiWeb.JsonApi

  @title "Vision core unavailable"
  @detail "the vision core does not run, or is restarting"

  @doc """
  Runs `action`, a controller action on `conn`, and answers its
  response; a 503 when a call to a server exits in it. Any other exit is
  left to the endpoint.
  """
  @spec answer(Plug.Conn.t(), (-> Plug.Conn.t())) :: Plug.Conn.t()
  def answer(conn, action) do
    action.()
  catch
    :exit, {reason, {GenServer, :call, [server | _arguments]}} ->
      Logger.debug("#{inspect(server)} did not answer: #{inspect(reason)}")
      JsonApi.error(conn, 503, @detail, title: @title)
  end
end
