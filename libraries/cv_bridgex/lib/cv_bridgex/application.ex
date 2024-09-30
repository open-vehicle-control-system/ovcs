defmodule CvBridgex.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {CvBridgex.CvCamera, []}
    ]

    opts = [strategy: :one_for_one, name: CvBridgex.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
