# Changelog

## v0.11.2 - 2023-06-10

* Changes
  * Fix Elixir 1.15 deprecation warning

## v0.11.1 - 2023-01-23

* Changes
  * Support VintageNet v0.13.0
  * Various minor documentation updates

## v0.11.0 - 2022-04-30

This release requires Elixir 1.11 or later and VintageNet 0.12.0.

* Changes
  * Add `VintageNetEthernet.quick_configure` to easily setup a wired Ethernet
    network that uses dynamic addressing.

## v0.10.3

* Changes
  * Support `vintage_net v0.11.x` as well

## v0.10.2

* New features
  * Support setting the MAC address via either a string or an MFA that will be
    called to read the MAC address. See the `:mac_address` parameter.

## v0.10.1

* Bug fixes
  * Fix new compiler warnings when built with Elixir 1.12

## v0.10.0

This release contains no code changes but it has been updated to use
`vintage_net v0.10.0`. No changes to applications are needed.

## v0.9.0

* New features
  * Synchronize with vintage_net v0.9.0's networking program path API update

## v0.8.0

* New features
  * Support vintage_net v0.8.0's `required_ifnames` API update

## v0.7.0

Initial `vintage_net_ethernet` release. See the [`vintage_net v0.7.0` release
notes](https://github.com/nerves-networking/vintage_net/releases/tag/v0.7.0)
for upgrade instructions if you are a `vintage_net v0.6.x` user.
