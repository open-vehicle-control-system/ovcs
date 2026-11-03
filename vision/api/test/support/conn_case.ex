defmodule VisionApiWeb.ConnCase do
  @moduledoc "Test case for controller tests: a fresh `conn` and `Phoenix.ConnTest`."
  use ExUnit.CaseTemplate

  using do
    quote do
      @endpoint VisionApiWeb.Endpoint

      import Plug.Conn
      import Phoenix.ConnTest
    end
  end

  setup _tags do
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end
end
