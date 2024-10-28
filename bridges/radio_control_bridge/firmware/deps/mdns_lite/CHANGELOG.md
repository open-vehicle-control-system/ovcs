# Changelog

This project follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## v0.8.11 - 2024-09-10

* Bug fixes
  * Fix `MdnsLite.InetMonitor` to properly remove interfaces that don't exist in a subsequent update. (@kevinschweikert)
  * Exclude "__unknown" interfaces to ignore interfaces that VintageNet can't get link info on. (@ConnorRigby)
  * Don't crash on other Unix-like OSes (@mneumann)

## v0.8.10 - 2024-02-26

* Bug fixes
  * Really fix crash when cleaning up responders when a network goes down. The
    fix in v0.8.9 had an issue that prevented it from working.

## v0.8.9 - 2024-02-02

* Bug fixes
  * Switch bridge recursive lookup to default to false. The issue that this
    works around has been fixed since OTP 24.1.
  * Handle crash when cleaning up responders when a network goes down.

## v0.8.8 - 2023-05-26

* New feature
  * IPv6 queries are now supported. Responding to IPv6 isn't supported yet. To
    use this, be sure to set `ipv4_only: false` since this isn't the default.
    Thanks to @bjyoungblood for this feature.

## v0.8.7 - 2023-02-12

* Fixed
  * Fix Elixir 1.15 deprecation warnings

## v0.8.6 - 2022-06-14

* Fixed
  * Fixed an issue that caused the DNS bridge to stop working with OTP 25.

## v0.8.5 - 2022-04-28

* Fixed
  * If a network interface changes IP addresses, there would be a flurry of
    crashes when it was no longer possible to bind to the interface. This stops
    behavior and shuts down the responder for the interface.

## v0.8.4 - 2021-11-13

* New feature
  * VintageNet is an optional dependency now. This makes it possible to use
    MdnsLite outside of Nerves much more easily.

* Fixed
  * Use the new DNS encoder/decoder from OTP 24.1.5. This fixes a regression
    with OTP 24.1.2 where the DNS encoder and decoder was updated to be more
    correct in how it handled the DNS class. mDNS repurposes the high bit of the
    DNS class. Previously we had gotten lucky. OTP 24.1.5 adds support for the
    bit. To make sure that MdnsLite can work on other OTP versions, the new
    OTP code has been vendored and included with MdnsLite.

## v0.8.3 - 2021-10-07

* Fixed
  * Added configuration and runtime support for setting the instance name. This
    was incorrectly removed in v0.8.0. By default, MdnsLite will advertise
    itself using the hostname. This works, but looks unfriendly in the service
    discovery results. Setting the instance name lets you advertise with a nice
    human readable name. Thanks to Mat Trudel for both catching this regression
    and fixing it.

## v0.8.2 - 2021-09-23

* Fixed
  * Fix calls to `:socket.setopt/3` to support OTP 22 and OTP 23. Thanks to
    Peter Madsen for finding this and providing a fix.

## v0.8.1 - 2021-09-19

* Fixed
  * Fix interface monitor crash when a network interface gets removed.

## v0.8.0

This release is a major update to MdnsLite to support making queries in
addition to responding to queries. The runtime API is not backwards compatible.
If you're only using the application environment to configure MdnsLite, you
should be ok.

* New features
  * Make mDNS requests
  * Add a DNS bridge for Erlang's DNS resolver. This enables Erlang
    distribution and `:gen_tcp` users to be passed `.local` hostnames. See docs
    for how to configure
  * mDNS record caching
  * mDNS record inspection - both for ones MdnsLite advertises and for ones in
    the caches
  * AAAA record support - Proper IPv6 support is still not available

* Bug fixes
  * MdnsLite now uses `:socket` to send and receive mDNS messages. This fixes
    several issues where multicast packets were being mixed up between network
    interfaces.

## v0.7.0

* Breaking change
  * Change optional dependency on VintageNet to a mandatory one. Probably all
    `:mdns_lite` users were already using VintageNet and since Mix releases
    doesn't support optional dependencies yet, some users got errors when the
    release misordered them. This avoids the problem.

* Improvements
  * Removed the `:dns` package dependency. There as an Erlang crypto API call in
    a dependency of `:dns` that was removed in OTP 24. This change makes it
    possible to use `:mdns_lite` on OTP 24 without worrying about a missing
    crypto API call.

## v0.6.7

* Improvements
  * Exclude `"wwan0"` by default. These interfaces are cellular links like ppp
    and it's not appropriate to respond to mDNS on them either.

## v0.6.6

* Bug fixes
  * Advertise services based on service names & not hostname. Thanks to Matt
    Trudel for this fix.

## v0.6.5

* Bug fixes
  * Reuse addresses and ports when binding to the multicast socket to coexist
    with other mDNS software. Thanks to Eduardo Cunha and Matt Myers for the
    updates.

## v0.6.4

* New features
  * Support custom TXT record contents. See the `:txt_payload`. Thanks to
    Eduardo Cunha for adding this.

## v0.6.3

* Bug fixes
  * Update default so that ppp interfaces are ignored. This prevents surprises
    of having a responder run on a cellular link.

## v0.6.2

* Bug fixes
  * Fix crash when handling undecodable mDNS messages

## v0.6.1

* Handle nil from VintageNet reports

## v0.6.0

* Allow mdns host to be change at runtime
* New network monitor: VintageNetMonitor

## v0.5.0

* Allow services to be added and removed at runtime.

## v0.4.3

* Correct typos and white space
* Comment out logger messages

## v0.4.2

* Remove un-helpful Logger.debug statements - Issue #49
* Put this file into the proper order.

## v0.4.1

* Correct bad tag in README.md and correct grammar.
* Correct documentation of the MdnsLite module

## v0.4.0

* The value of host in the configuration file can have two values. The second can serve as an alias for the first.
* Updated documentation and comments.
* Created a new test.

## v0.3.0

* Remove a superfluous map from the config.

## v0.2.1

* Update README to reflect changes in previous version.

## v0.2.0

* Much better alignment with RFC 6763 - DNS Service-based discovery.
* Affects handling of SRV and PTR queries.

## v0.1.0

* Initial release
