# Changelog

## v1.0.1

* Bug fixes
  * Sync updates to the environment with the OS to ensure that they're written
    in case power is removed shortly afterwards. Thanks @parherman.

## v1.0.0

This release only changes the version number and updates documentation. No code
changes were made.

## v0.3.0

This release adds support for redundant U-Boot environments. It reduces the main
API to `UBootEnv.read/1` and `UBootEnv.write/2`. If you only use those
functions, your code should work without change.

* New features
  * Redundant U-Boot support

## v0.2.0

This release breaks several APIs so please review your code.

The first break is that `UBootEnv.encode/2` returns iodata now. In general, the
return value would end up being passed places that supported iodata, but it had
previously been spec'd as returning a binary.

The second break is that `UBootEnv.decode/1` now does the reverse of
`UBootEnv.encode/2`. It previously was a convenience method, but it was public.
It is not expected that many people used the previous function.

* Bug fixes
  * Reduce the amount of garbage generated when encoding and decoding. A manual
    call to `:erlang.garbage_collect/1` can free the garbage, but it stays
    around long enough to make any process calling this library to show up with
    megabytes more heap used.

## v0.1.1

* Bug fixes
  * handle trailing whitespace in config
  * handle 0-length strings in config
  * handle `:eof` values when reading from env

* Updated dependencies
  * `ex_doc` ~> 0.20

## v0.1.0

Initial release
