defmodule VisionApiWeb do
  @moduledoc """
  The vision API's web layer: `use VisionApiWeb, :router | :controller |
  :channel`, or `{:channel, options}` to pass `Phoenix.Channel` its
  options, such as `:log_join`.
  """

  @doc "The `priv/static` entries `Plug.Static` serves; the rest falls through to the dashboard."
  def static_paths, do: ~w(assets favicon.svg)

  def router do
    quote do
      use Phoenix.Router, helpers: false

      import Plug.Conn
      import Phoenix.Controller
    end
  end

  def controller do
    quote do
      use Phoenix.Controller, formats: [:json]

      import Plug.Conn
    end
  end

  def channel(options \\ []) do
    quote do
      use Phoenix.Channel, unquote(options)
    end
  end

  defmacro __using__({which, options}) when is_atom(which) do
    apply(__MODULE__, which, [options])
  end

  defmacro __using__(which) when is_atom(which) do
    apply(__MODULE__, which, [])
  end
end
