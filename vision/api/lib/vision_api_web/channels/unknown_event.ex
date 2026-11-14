defmodule VisionApiWeb.UnknownEvent do
  @moduledoc """
  A channel's answer to an event it does not take: an error reply,
  `%{reason: "unknown event"}`. A channel without a clause for a pushed
  event would stop instead.
  """

  @doc "The `handle_in/3` reply refusing the event."
  @spec refuse(Phoenix.Socket.t()) :: {:reply, {:error, map()}, Phoenix.Socket.t()}
  def refuse(socket), do: {:reply, {:error, %{reason: "unknown event"}}, socket}
end
