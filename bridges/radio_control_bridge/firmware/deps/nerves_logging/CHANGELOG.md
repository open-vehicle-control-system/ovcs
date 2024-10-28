# Changelog

## v0.2.2 - 2023-11-05

* Changes
  * Label log messages coming from syslog and the kernel ringbuffer as `$syslog`
    and `$kmsg`. These are in the "application" field. This helps when log
    messages by application since these used to be `nil`.

## v0.2.1 - 2023-06-30

* Changes
  * Fix Elixir 1.15 Logger warning

## v0.2.0 - 2022-07-04

* Changes
  * No longer automatically start log tailers. Users must add
    `NervesLogging.KmsgTailer` and `NervesLogging.SyslogTailer` to their
    supervision trees. This simplifies the logic for whether to start the
    loggers or not. Very few users will need to do anything. It will be handled
    by `Nerves.Runtime`.

## v0.1.1 - 2022-06-03

* Changes
  * Don't crash when lacking permissions to read logs. Restarting doesn't fix
    the permission issue so this ends up being terminal. The error will be
    logged.

## v0.1.0 - 2022-04-26

Extract system logging from `nerves_runtime`.

* Updates
  * Require Elixir 1.11 and remove all syslog-to-Elixir log level conversion code
    since Elixir accepts all of the syslog levels now.
  * Remove the `:severity` field from log messages since it's redundant now.
    It's unknown if this field was actually used.
