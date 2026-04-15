defmodule <%= @module %>.Application do
  @moduledoc """
  Local-dev Application for `<%= @upper %>`. Installed only when
  `Mix.target() == :host`; firmware builds (`./ovcs build <%= @name %>
  vms`<%= if @infotainment do %> / `./ovcs build <%= @name %> infotainment`<% end %> /
  `./ovcs build <%= @name %> <bridge-id>`) each run in their own
  Nerves image and never load this module.

  Supervision is delegated to `OvcsVehicle.LocalSupervisor`, which
  reads `<%= @module %>.bridge_firmwares/0` and starts the bundled
  bridges' `children/0` (namespaced per firmware_id). The VMS<%= if @infotainment do %> and
  infotainment<% end %> cores auto-start via their own OTP apps — they're
  transitive deps of this package.
  """
  use Application

  @impl true
  def start(_type, _args) do
    Supervisor.start_link(
      [{OvcsVehicle.LocalSupervisor, <%= @module %>}],
      strategy: :one_for_one,
      name: __MODULE__.Supervisor
    )
  end
end
