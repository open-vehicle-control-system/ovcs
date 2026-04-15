import Config

# Compile-time config used when the vehicle package is run as its
# own local-dev app (`cd vehicles/<%= @name %> && iex -S mix`, or
# `./ovcs run <%= @name %>`). Firmware builds go through each side's
# own Nerves project (`vms/firmware`<%= if @infotainment do %>,
# `infotainment/firmware`<% end %>, `bridges/firmware`) and never
# read this file.

# Wire the composers so <%= if @infotainment do %>vms_core + infotainment_core<% else %>vms_core<% end %> dispatch
# through <%= @module %> without needing the VEHICLE env var.
config :vms_core, :vehicle, <%= @module %>.Vms.Composer
<%= if @infotainment do %>config :infotainment_core, :vehicle, <%= @module %>.Infotainment.Composer
<% end %>
# Cantastic reads the vehicle's priv/can<%= if @infotainment do %> (merging vms.yml +
# infotainment.yml with `priv_can_config_path` as a list)<% end %> so the
# single BEAM serves <%= if @infotainment do %>both sides<% else %>the VMS<% end %>. Update
# `can_network_mappings` to cover every bus your composer declares
# via `default_can_mapping(:host)`.
config :cantastic,
  otp_app: :<%= @name %>,
  priv_can_config_path: <%= if @infotainment do %>["can/vms.yml", "can/infotainment.yml"]<% else %>"can/vms.yml"<% end %>,
  setup_can_interfaces: false,
  enable_socketcand: false,
  can_network_mappings: [
    {"ovcs", "vcan0"}
  ]

# Pull in the per-side endpoint + repo configs. Each imports its
# own `#{config_env()}.exs` at the bottom.
import_config "../../../vms/api/config/config.exs"
<%= if @infotainment do %>import_config "../../../infotainment/api/config/config.exs"
<% end %>
# Start the Phoenix endpoint(s) under plain `iex -S mix` without
# needing `mix phx.server`.
config :vms_api, VmsApiWeb.Endpoint, server: true
<%= if @infotainment do %>config :infotainment_api, InfotainmentApiWeb.Endpoint, server: true
<% end %>