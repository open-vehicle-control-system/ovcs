defmodule NervesUEvent.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    opts = Application.get_all_env(:nerves_uevent)

    children = [
      {PropertyTable, name: NervesUEvent},
      {NervesUEvent.UEvent, opts}
    ]

    # :rest_for_one to handle the rare case where the PropertyTable
    # crashes. Restarting UEvent will scan the system.
    opts = [strategy: :rest_for_one, name: NervesUEvent.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
