# Changelog

## v1.0.0

This release adds support for Elixir 1.17 and removes support for Elixir 1.12
and earlier. It has no other functional differences with v0.4.3.

## v0.4.3

This release is almost entirely code cleanup and improved documentation.
The only notable change is you now must use atoms or module names for the
`:name` option with daemon processes.

* Updated
  * Remove registry and rely on GenServer name registration
  * Excluded unused `:user_passwords` key when `:pwdfun` is used

## v0.4.2

* Fixed
  * Fix all compiler warnings and deprecations with Elixir 1.15

## v0.4.1

* Fixed
  * Default `SSHSubsystemFwup` config would overwrite any user defined config
    preventing FWUP handling customization (thanks @ConnorRigby!)

## v0.4.0

* New features
  * `NervesSSH.Options` now supports a `:name` key to use when starting the
    SSH daemon. This allows a user to run multiple SSH daemons on the same
    device without name conflicts (thanks @SteffenDE)

* Fixed
  * The SSH daemon could fail to start if the system/user directories were bad
    or if the file system was not ready/mounted to support writing to disk. In
    those cases, NervesSSH now attempts to write to tmpfs at
    `/tmp/nerves_ssh/<original path>` to help prevent the daemon from crashing

## v0.3.0

`NervesSSH` now requires Elixir >= 1.10 and OTP >=23

* New features
  * Support for adding authorized public keys at runtime
  * Authorized public keys are also saved/read from `authorized_keys` file
  * Support for adding user credentials at runtime
  * Server host key is now generated on device if missing rather than
    relying on hard-coded host key provided by this lib. This should not
    be a breaking change, though you may be prompted to trust the new
    host key if `StrictHostKeyChecking yes` is set in your `~/.ssh/config`

## v0.2.3

* New features
  * Initial support for using `scp` to copy files. Not all `scp` features work,
    but uploading and downloading individual files does. Thanks to Connor Rigby
    and Binary Noggin for this feature.

## v0.2.2

* Improvements
  * Fix a deprecation warning on OTP 24.0.1 and later
  * Add support for LFE shells. LFE must be a dependency of your project for
    this to work.

## v0.2.1

* Improvements
  * Raise an error at compile-time if the application environment looks like
    it's using the `:nerves_firmware_ssh` key instead of the `:nerves_ssh` one.

## v0.2.0

This update makes using the application environment optional. If you don't have
any settings for `:nerves_ssh` in your `config.exs`, `:nerves_ssh` won't start.
You can then add `{NervesSSH, your_options}` to the supervision tree of your
choice.

## v0.1.0

Initial release
