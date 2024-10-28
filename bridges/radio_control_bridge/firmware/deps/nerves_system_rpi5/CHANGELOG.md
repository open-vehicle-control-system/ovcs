# Changelog

This project does NOT follow semantic versioning. The version increases as
follows:

1. Major version updates are breaking updates to the build infrastructure.
   These should be very rare.
2. Minor version updates are made for every major Buildroot release. This
   may also include Erlang/OTP and Linux kernel updates. These are made four
   times a year shortly after the Buildroot releases.
3. Patch version updates are made for Buildroot minor releases, Erlang/OTP
   releases, and Linux kernel updates. They're also made to fix bugs and add
   features to the build infrastructure.

## v0.3.1

This is a security/bug fix update.

* Changes
  * Enable QMI kernel modules to support many cellular modems without a Nerves
    system update

* Updated dependencies
  * [nerves_system_br v1.28.3](https://github.com/nerves-project/nerves_system_br/releases/tag/v1.28.3)
  * [Buildroot 2024.05.2](https://lore.kernel.org/buildroot/87zfpfh147.fsf@dell.be.48ers.dk/T/)
  * [Erlang/OTP 27.0.1](https://erlang.org/download/OTP-27.0.1.README)

## v0.3.0

This is a major Erlang and Buildroot.

Please see the [nerves_system_br v1.28.0 release notes](https://github.com/nerves-project/nerves_system_br/releases/tag/v1.28.0)
for upgrade instructions if you've forked this system.

* Changes
  * Elixir 1.17 and Erlang/OTP 27 support
  * Reduce copy/pasted definitions in the `fwup.conf` by extracting them to
    `fwup_include/fwup-common.conf`. (No functional changes)

* Fixes
  * The serial numbers returned by `Nerves.Runtime.serial_number/0` now contain
    the whole serial number. If you forked this system, check the
    `boardid.config` and `erlinit.config` for the changes and to keep the
    hostname the same.

* Updated dependencies
  * [nerves_system_br v1.28.1](https://github.com/nerves-project/nerves_system_br/releases/tag/v1.28.1)
  * [Buildroot 2024.05](https://lore.kernel.org/buildroot/87bk46tjk2.fsf@dell.be.48ers.dk/T/)
  * [Erlang/OTP 27.0](https://erlang.org/download/OTP-27.0.README)

## v0.2.1

This is a security/bug fix update.

* Changes
  * Enable the `wpa_supplicant` option for allow wired 802.1x authentication

* Package updates
  * [Erlang/OTP 26.2.5](https://erlang.org/download/OTP-26.2.5.README)
  * [Buildroot 2024.02.1](https://lore.kernel.org/buildroot/87jzlp9u5e.fsf@48ers.dk/T/)

## v0.2.0

This is a major Buildroot update.

Please see the [nerves_system_br v1.27.0 release notes](https://github.com/nerves-project/nerves_system_br/releases/tag/v1.26.0)
for upgrade instructions if you've forked this system.

* Changes
  * Important documentation update to replace ttyS0 with ttyAMA10 for getting
    the IEx prompt on the debug UART
  * The `libcamera` and `rpicam_apps` packages have been replaced with the
    Raspberry Pi-forked versions for better compatibility. Please see
    `nerves_system_br` release notes.

* Updated dependencies
  * Linux 6.1.73 (Raspberry Pi 20240124 release)
  * [nerves_system_br v1.27.0](https://github.com/nerves-project/nerves_system_br/releases/tag/v1.27.0)
  * [Buildroot 2024.02](https://lore.kernel.org/buildroot/87msrczp4z.fsf@48ers.dk/)
  * [Erlang/OTP 26.2.3](https://erlang.org/download/OTP-26.2.3.README)

## v0.1.0

This is a major Buildroot update.

Please see the [nerves_system_br v1.26.0 release notes](https://github.com/nerves-project/nerves_system_br/releases/tag/v1.26.0)
for upgrade instructions if you've forked this system.

* New features
  * Add the imx296 overlays for the Raspberry Pi Global Shutter Camera

* Updated dependencies
  * [Erlang/OTP 26.2.2](https://erlang.org/download/OTP-26.2.2.README)
  * [nerves_system_br v1.26.1](https://github.com/nerves-project/nerves_system_br/releases/tag/v1.26.1)
  * [Buildroot 2023.11.1](https://lore.kernel.org/buildroot/87cyu2k2gu.fsf@48ers.dk/T/)

## v0.0.2

This is a security/bug fix update.

 Package updates
  * [Erlang/OTP 26.2.1](https://erlang.org/download/OTP-26.2.1.README)
  * [nerves_heart 2.3.0](https://github.com/nerves-project/nerves_heart/releases/tag/v2.3.0)

## v0.0.1

This is an initial release to make it easier for more people to test Nerves on
the Raspberry Pi 5. Future releases may be incompatible and this one might have
some frustrating bugs.
