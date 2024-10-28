# Changelog

## v2.0.3 - 2024-6-5

* Changes
  * Fix Elixir 1.17 deprecation warnings

## v2.0.2 - 2023-2-12

* Changes
  * Fix Elixir 1.15 deprecation warnings

## v2.0.1 - 2022-8-4

* Changes
  * Fix Elixir 1.14 warning during compilation
  * Raise minimum Elixir version to 1.11 similar to other Nerves-related
    libraries. It should still work, but it's no longer verified on CI, and I'm
    no longer supporting issues with earlier Elixir versions.

## v2.0.0 - 2022-3-6

This release removes `OneDHCPD.start_server/2` and makes OneDHCPD a library
rather than an OTP Application. If you're using `VintageNetDirect`, you won't
notice this change since it didn't use `OneDHCPD.start_server/2` anyway. If
you're using `OneDHCPD.start_server/2`, then add `OneDHCP.Server` to your
application's supervision tree.

## v1.0.0 - 2021-10-28

This release bumps the version number to 1.0.0. No functional changes were made.

* Improvements
  * Minor code and documention cleanup

## v0.2.5

* Bug fixes
  * Fix missing `:crypto` dependency warning on Elixir 1.11

## v0.2.4

* Bug fixes
  * Fix C compiler warning

## v0.2.3

* Improvements
  * Added `OneDHCPD.prefix_length()` for a more convenient integration with
    `vintage_net`

* Bug fixes
  * Non-code affecting Dialyzer and compiler warning fixes
  * Fixed a currently unused DHCP option encoder (found when Dialyzing)

## v0.2.2

* Bug fixes
  * Switch from 172.16.0.0/12 to 172.31.0.0/16 for the default addresses. This
    avoids conflicts with Docker's use of 172.18.0.0/16.

## v0.2.1

* Bug fixes
  * Move build products under `_build` so that it's not required to build clean
    between switching targets.

## v0.2.0

* Bug fixes
  * Send DHCP NAKs when clients request the wrong IP address. Speeds up getting
    the right address when switching networks.

## v0.1.0

Initial release
