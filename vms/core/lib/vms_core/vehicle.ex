defmodule VmsCore.Vehicle do
  @moduledoc """
  Contract for the VMS side of a vehicle package.

  A vehicle package exposes a module implementing this behaviour; it is the
  single entry point `vms_core` uses to wire a vehicle-specific supervision
  tree, dashboard, and generic controller configuration.
  """

  @doc "The vehicle's VMS components and managers, started under `VmsCore.Supervisor`."
  @callback children() :: [:supervisor.child_spec() | {module(), term()} | module()]

  @doc "The dashboard's pages and blocks, served by the VMS API."
  @callback dashboard_configuration() :: map()

  @doc "Each generic controller's pin configuration, keyed by controller name."
  @callback generic_controllers() :: map()

  @doc "The OTP application whose `priv/` holds the vehicle's CAN YAMLs."
  @callback can_config_otp_app() :: atom()

  @doc "The VMS CAN topology YAML, relative to that application's `priv/`."
  @callback can_config_path() :: String.t()

  @doc """
  The `CAN_NETWORK_MAPPINGS` used on the host or on the target when the
  variable is unset.
  """
  @callback default_can_mapping(:host | :target) :: String.t()

  @optional_callbacks [dashboard_configuration: 0, generic_controllers: 0]
end
