defmodule VmsCore.Vehicle do
  @moduledoc """
  Contract for the VMS side of a vehicle package.

  A vehicle package exposes a module implementing this behaviour; it is the
  single entry point `vms_core` uses to wire a vehicle-specific supervision
  tree, dashboard, and generic controller configuration.
  """

  @callback children() :: [:supervisor.child_spec() | {module(), term()} | module()]
  @callback dashboard_configuration() :: map()
  @callback generic_controllers() :: map()
  @callback can_config_otp_app() :: atom()
  @callback can_config_path() :: String.t()

  @optional_callbacks [dashboard_configuration: 0, generic_controllers: 0]
end
