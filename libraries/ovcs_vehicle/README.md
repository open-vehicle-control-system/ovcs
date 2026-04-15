# OvcsVehicle

Shared top-level behaviour for OVCS vehicle packages.

A vehicle package is a single Mix app that bundles both its VMS side and
its infotainment side. Its top-level module implements this behaviour
and exposes the two side-specific composers (themselves implementing
`VmsCore.Vehicle` and `InfotainmentCore.Vehicle`). Configuring a
consumer with a single module — e.g. `config :vms_core, :vehicle, Ovcs1`
— is enough to wire the full stack.

```elixir
defmodule Ovcs1 do
  @behaviour OvcsVehicle
  def name, do: "OVCS1"
  def vms, do: Ovcs1.Vms
  def infotainment, do: Ovcs1.Infotainment
  def can_config_otp_app, do: :ovcs1
  def nerves_target(:vms), do: :rpi4
  def nerves_target(:infotainment), do: :rpi5
end
```
