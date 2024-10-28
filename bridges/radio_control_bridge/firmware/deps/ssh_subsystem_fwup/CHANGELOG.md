# Changelog

## v0.6.2

* Improvements
  * Fix `mix upload` so that its invocation of `ssh` no longer overrides
    `LD_LIBRARY_PATH`. (@ringlej)
  * Fix/clean up some typespecs

## v0.6.1

* Improvements
  * `mix upload` now attempts to display the UUID of the firmware as well

## v0.6.0

* New features
  * Added a `:precheck_callback` option to support updating firmware update
    options at runtime and to stop updates from happening at critical times
  * Added a `:fwup_env` option for passing OS environment variables to fwup
  * Support setting default system-wide options in the application config in
    addition to the subsystem spec. The subsystem spec takes precedence.

## v0.5.2

* Improvements
  * Improve instructions for how to update from `nerves_firmware_ssh`

## v0.5.1

This releases adds a check for old `upload.sh` scripts to warn users that
they'll need to update it.

## v0.5.0

Initial release.

This factors out the SSH subsystem from
[`nerves_firmware_ssh`](https://github.com/nerves-project/nerves_firmware_ssh)
and removes all ssh server code. The user of this library now has to start a
server themselves. This makes it possible to run the firmware update on port 22
and removes the constraint of needing to hard code authorized ssh public keys.
