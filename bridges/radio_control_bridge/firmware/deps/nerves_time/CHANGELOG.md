# Changelog

## v0.4.8

* Fixes
  * Fix "Cannot initialize rtc" error that's in v0.4.7. (thanks @joshk)
  * Add "[NervesTime]" to log messages to make it easier to identify where they
    come from.

## v0.4.7

* Updates
  * Don't create communications socket file if not starting `ntpd` so that it
    doesn't need to be cleaned up. (thanks @joshk)
  * Add and clean up missing typespecs

## v0.4.6

* Updates
  * Build cleanly on Elixir 1.15. This raises the minimum supported Elixir
    version to 1.11 since we no longer test on early versions.

## v0.4.5

* New feature
  * Support blocking NervesTime startup until initialized with a valid time.
    See [Startup](https://github.com/nerves-time/nerves_time#startup) doc and
    `NervesTime.Waiter` for more info (thanks @LostKobrakai :heart:)

## v0.4.4

* Updates
  * Allow `muontrap v1.0.0` to be used.

## v0.4.3

This release only reduces Makefile prints and has no code changes. It is a safe
update.

## v0.4.2

* New feature
  * Added `NervesTime.set_system_time/1` to manually set the system clock.
    Thanks to Eric Rauer for this.

## v0.4.1

* Bug fixes
  * Fix crash when setting time.

## v0.4.0

* New features
  * Added `NervesTime.RealTimeClock` behaviour to support external RTC
    implementations. The default RTC is still FileTime. I.e., approximate an RTC
    by periodically updating the modified time on a file and reading it back at
    boot. See [github.com/nerves-time](https://github.com/nerves-time) for
    example RTC implementations.

* Bug fixes
  * `NervesTime.synchronized?/0` will stay true once NTP synchronizes. It will
    not revert to false unless a crash happens and the NTP code restarts. This
    should address some confusion, since in practice the function was being used
    to check whether the system time could be used. Bouncing the answer between
    true and false depending on ntp reports was confusing since the system time
    had already been set once and was plenty close to the real time.

## v0.3.2

* Improvements
  * Further reduce ntpd's logging. It is just too much especially when the
    internet is down.

## v0.3.1

* Bug fixes
  * Move ntpd's prints to the log. The previous prints to the console were quite
    annoying to say the least.
  * Remove the build timestamp so that `nerves_time` builds are reproducible.
    This is important for users that want to recreate firmware images with as
    few differences as possible. The build timestamp had restricted the earliest
    allowed time. The earliest time is now hardcoded, but can be overridden by
    application config (same with the latest possible time.)

## v0.3.0

IMPORTANT: This release moves `Nerves.Time` to the `NervesTime` namespace. If
you are using the API, you will need to rename every instance of `Nerves.Time`
in your code to `NervesTime`.

* Bug fixes
  * `ntpd` crash detection and restart have been simplified by using
    `MuonTrap.Daemon`. This should fix an issue that was seen with `ntpd` not
    getting restarted after it crashed.
  * `NervesTime.synchronized?/0` would return synchronized when changing NTP
    servers and right after restarting `ntpd`. It will return `false` now and
    switch to `true` when time really has been synchronized.

* Improvements
  * Simplified ntpd reporting code. No more regular expressions. Reports are
    sent via a Unix Domain socket and encoded as Erlang terms. This deleted a
    lot of string parsing code that felt brittle.
  * Added a restart delay on unclean `ntpd` restarts to prevent pegging public
    NTP servers. The delay is currently a minute since `ntpd` crashes are not
    well-understood. Luckily, this seems like a rare event.
  * Added more tests to cover NTP use

## v0.2.1

* Improvements
  * Move C build products under `_build`. This lets you switch targets with out
    cleaning builds in between.

## v0.2.0

* Added support for configuring NTP servers at runtime. Thanks to @ConnorRigby
  for sending a PR for this
* Added `Nerves.Time.restart_ntpd/0` for users who know external information
  about good times to bounce the NTP daemon so that it syncs more quickly
* Fixed naming of `is_synchronized/0` to be `synchronized?/0`. Thanks to
  @brodeuralexis for catching my slip.

## v0.1.0

Initial release
