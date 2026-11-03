defmodule VisionApiWeb.ChannelCase do
  @moduledoc "Test case for channel tests: `Phoenix.ChannelTest` on the dashboard socket."
  use ExUnit.CaseTemplate

  using do
    quote do
      @endpoint VisionApiWeb.Endpoint

      import Phoenix.ChannelTest
    end
  end
end
