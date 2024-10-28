# Changelog

## v0.10.7 - 2022-01-22

* Changes
  * Support `vintage_net v0.13.0`

## v0.10.6 - 2022-04-30

* Changes
  * Support `vintage_net v0.12.0`

## v0.10.5

* Changes
  * Support `one_dhcpd v2.0.0` - OneDHCPD 2.0 removes functions that
    VintageNetDirect didn't use.

## v0.10.4

* Changes
  * Fix issue where manually specifying a hostname would cause the subnet to be
    set incorrectly in the DHCP responses. Huge thanks to @aadavids for finding
    and fixing this.

## v0.10.3

* Changes
  * Support `one_dhcpd v1.0.0` as well.

## v0.10.2

* Changes
  * Support `vintage_net v0.11.x` as well.

## v0.10.1

* Bug fixes
  * Fix new compiler warnings when built with Elixir 1.12

## v0.10.0

This release contains no code changes. It only updates the `vintage_net`
dependency to allow `vintage_net v0.10.0` to be used.

## v0.9.0

* New features
  * Synchronize with vintage_net v0.9.0's networking program path API update

## v0.8.0

* New features
  * Support vintage_net v0.8.0's `required_ifnames` API update

## v0.7.0

Initial `vintage_net_direct` release. See the [`vintage_net v0.7.0` release
notes](https://github.com/nerves-networking/vintage_net/releases/tag/v0.7.0)
for upgrade instructions if you are a `vintage_net v0.6.x` user.
