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

## v0.12.1

This is a security/bug fix update.

* Updated dependencies
  * [nerves_system_br v1.28.3](https://github.com/nerves-project/nerves_system_br/releases/tag/v1.28.3)
  * [Buildroot 2024.05.2](https://lore.kernel.org/buildroot/87zfpfh147.fsf@dell.be.48ers.dk/T/)
  * [Erlang/OTP 27.0.1](https://erlang.org/download/OTP-27.0.1.README)

## v0.12.0

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

## v0.11.1

This is a security/bug fix update.

* Changes
  * Enable the `wpa_supplicant` option for allow wired 802.1x authentication

* Package updates
  * [Erlang/OTP 26.2.5](https://erlang.org/download/OTP-26.2.5.README)
  * [Buildroot 2024.02.1](https://lore.kernel.org/buildroot/87jzlp9u5e.fsf@48ers.dk/T/)

## v0.11.0

This is a major Buildroot update.

Please see the [nerves_system_br v1.27.0 release notes](https://github.com/nerves-project/nerves_system_br/releases/tag/v1.26.0)
for upgrade instructions if you've forked this system.

* Changes
  * Enabled WPA3 support in `wpa_supplicant`. WPA3 won't work, but specifying it
    in a configuration won't crash the supplicant.

* Updated dependencies
  * Linux 6.1.73 (Raspberry Pi 20240124 release)
  * [nerves_system_br v1.27.0](https://github.com/nerves-project/nerves_system_br/releases/tag/v1.27.0)
  * [Buildroot 2024.02](https://lore.kernel.org/buildroot/87msrczp4z.fsf@48ers.dk/)
  * [Erlang/OTP 26.2.3](https://erlang.org/download/OTP-26.2.3.README)

## v0.10.0

This is a major Buildroot update.

Please see the [nerves_system_br v1.26.0 release notes](https://github.com/nerves-project/nerves_system_br/releases/tag/v1.26.0)
for upgrade instructions if you've forked this system.

* Updated dependencies
  * [Erlang/OTP 26.2.2](https://erlang.org/download/OTP-26.2.2.README)
  * [nerves_system_br v1.26.1](https://github.com/nerves-project/nerves_system_br/releases/tag/v1.26.1)
  * [Buildroot 2023.11.1](https://lore.kernel.org/buildroot/87cyu2k2gu.fsf@48ers.dk/T/)

## v0.9.1

This is a security/bug fix update.

*  Package updates
  * [Erlang/OTP 26.2.1](https://erlang.org/download/OTP-26.2.1.README)
  * [nerves_heart 2.3.0](https://github.com/nerves-project/nerves_heart/releases/tag/v2.3.0)

## v0.9.0

This is a major Buildroot and toolchain update.

Please see [nerves_system_br v1.25.0 release notes](https://github.com/nerves-project/nerves_system_br/releases/tag/v1.25.0)
for upgrade instructions if you've forked this system.

* Updated dependencies
  * [nerves_system_br v1.25.2](https://github.com/nerves-project/nerves_system_br/releases/tag/v1.25.2)
  * [Buildroot 2023.08.4](https://lore.kernel.org/buildroot/87o7f6t7fs.fsf@48ers.dk/T/)
  * [Erlang/OTP 26.1.2](https://erlang.org/download/OTP-26.1.2.README)

## v0.8.1

This is a security/bug fix update.

* Package updates
  * [nerves_system_br v1.24.1](https://github.com/nerves-project/nerves_system_br/releases/tag/v1.24.1)
  * [Erlang/OTP 26.1.1](https://erlang.org/download/OTP-26.1.1.README)
  * [Buildroot 2023.05.3](https://lore.kernel.org/buildroot/87h6ngup34.fsf@48ers.dk/T/)

## v0.8.0

This is a Buildroot version update that appears to mostly contain bug and
security fixes. It should be a low risk upgrade from v0.7.3.

* Updated dependencies
  * [nerves_system_br v1.24.0](https://github.com/nerves-project/nerves_system_br/releases/tag/v1.24.0)
  * [Buildroot 2023.05.2](https://lore.kernel.org/buildroot/87ledrkrpp.fsf@48ers.dk/T/), [2023.05.1](https://lore.kernel.org/buildroot/87351m8qm4.fsf@48ers.dk/T/), [2023.05](https://lore.kernel.org/buildroot/87r0qn2c77.fsf@48ers.dk/T/)
  * [Erlang/OTP 26.1](https://erlang.org/download/OTP-26.1.README)

## v0.7.3

* Updated dependencies
  * [nerves_system_br v1.23.3](https://github.com/nerves-project/nerves_system_br/releases/tag/v1.23.3)

## v0.7.2

This is a bug and security fix update. It should be a low risk upgrade.

* Fixes
  * Fix CTRL+R over ssh

* Updated dependencies
  * [nerves_system_br v1.23.2](https://github.com/nerves-project/nerves_system_br/releases/tag/v1.23.2)
  * [Buildroot 2023.02.2](https://lore.kernel.org/buildroot/87y1je6wva.fsf@48ers.dk/T/)

## v0.7.1

This release enables UART, I2C, and SPI support on the PMOD interfaces. See
`README.md` for device names.

* Updated dependencies
  * Linux 5.15.102 + Phytec patches

## v0.7.0

This is a major update that brings in Erlang/OTP 26 and Buildroot 2023.02.2.

* New features
  * CA certificates are included for OTP 26.

* Updated dependencies
  * [nerves_system_br v1.23.1](https://github.com/nerves-project/nerves_system_br/releases/tag/v1.23.1)
  * [Buildroot 2023.02.2](https://lore.kernel.org/buildroot/87wn03ifbl.fsf@48ers.dk/T/)
  * [Erlang/OTP 26.0.2](https://erlang.org/download/OTP-26.0.2.README)

## v0.6.2

This is a bug and security fix update. It should be a low risk upgrade.

* Updated dependencies
  * [nerves_system_br v1.22.5](https://github.com/nerves-project/nerves_system_br/releases/tag/v1.22.5)
  * [Buildroot 2022.11.3](https://lore.kernel.org/buildroot/878rfuxbxx.fsf@dell.be.48ers.dk/T/)

## v0.6.1

This is a bug fix and Erlang version bump from 25.2 to 25.2.3. It should be a
low risk upgrade from v0.6.0.

* Fixes
  * Set Erlang crash dump timer to 5 seconds, so if an Erlang crash dump does
    happen, it will run for at most 5 seconds. See erlinit.conf.

* Updated dependencies
  * [nerves_system_br v1.22.3](https://github.com/nerves-project/nerves_system_br/releases/tag/v1.22.3)
  * [Buildroot 2022.11.1](https://lore.kernel.org/buildroot/87ilh4dvax.fsf@dell.be.48ers.dk/T/#u)

## v0.6.0

This is a Buildroot version update that appears to mostly contain bug and
security fixes.

* Updated dependencies
  * [nerves_system_br v1.22.1](https://github.com/nerves-project/nerves_system_br/releases/tag/v1.22.1)
  * [Buildroot 2022.11](http://lists.busybox.net/pipermail/buildroot/2022-December/656980.html)
  * GCC 12.2

## v0.5.2

* Changes
  * Two Buildroot patch updates and an Erlang minor version update
  * Nerves Heart v2.0 is now included. Nerves Heart connects the Erlang runtime
    to a hardware watchdog. v2.0 has numerous updates to improve information
    that you can get and also has more safeguards to avoid conditions that could
    cause a device to hang forever.

* Updated dependencies
  * [nerves_system_br v1.21.6](https://github.com/nerves-project/nerves_system_br/releases/tag/v1.21.6)
  * [Erlang/OTP 25.2](https://erlang.org/download/OTP-25.2.README)
  * [Buildroot 2022.08.3](https://lore.kernel.org/buildroot/87r0x7z5cw.fsf@dell.be.48ers.dk/T/#u)
  * [nerves_heart v2.0.2](https://github.com/nerves-project/nerves_heart/releases/tag/v2.0.2)

## v0.5.1

* Changes
  * Reduce first-time Linux kernel download by using tarball source

* Updated dependencies
  * [nerves_system_br v1.21.2](https://github.com/nerves-project/nerves_system_br/releases/tag/v1.21.2)
  * [Erlang/OTP 25.1.2](https://erlang.org/download/OTP-25.1.2.README)

## v0.5.0

* Updated dependencies
  * [nerves_system_br v1.21.1](https://github.com/nerves-project/nerves_system_br/releases/tag/v1.21.1)
    and also see [nerves_system_br v1.21.0](https://github.com/nerves-project/nerves_system_br/releases/tag/v1.21.0)
  * [Buildroot 2022.08.1](http://lists.busybox.net/pipermail/buildroot/2022-October/652816.html)
  * [Erlang/OTP 25.1.1](https://erlang.org/download/OTP-25.1.1.README)

## v0.4.2

* Updated dependencies
  * [nerves_system_br v1.20.6](https://github.com/nerves-project/nerves_system_br/releases/tag/v1.20.6)
  * [Erlang/OTP 25.0.4](https://erlang.org/download/OTP-25.0.4.README)
  * [Buildroot 2022.05.2](http://lists.busybox.net/pipermail/buildroot/2022-August/650546.html)
  * Also see [Buildroot 2022.05.1 changes](http://lists.busybox.net/pipermail/buildroot/2022-July/647814.html)

## v0.4.1

* Updated dependencies
  * [nerves_system_br v1.20.4](https://github.com/nerves-project/nerves_system_br/releases/tag/v1.20.4)
  * [Erlang/OTP 25.0.3](https://erlang.org/download/OTP-25.0.3.README)

## v0.4.0

This release updates to Buildroot 2022.05 and uses GCC 11.3 (from GCC 10.3).

* Updated dependencies
  * [nerves_system_br v1.20.3](https://github.com/nerves-project/nerves_system_br/releases/tag/v1.20.3)
  * [Buildroot 2022.05](http://lists.busybox.net/pipermail/buildroot/2022-June/644349.html)
  * [Erlang/OTP 25.0.2](https://erlang.org/download/OTP-25.0.2.README)

## v0.3.0

This release updates to Buildroot 2022.02.1 and OTP 25.0. While this should be
an easy update for most projects, many programs have been updated. Please review
the changes in the updated dependencies for details.

* Updated dependencies
  * [nerves_system_br v1.19.0](https://github.com/nerves-project/nerves_system_br/releases/tag/v1.19.0)
  * [Buildroot 2022.02.1](http://lists.busybox.net/pipermail/buildroot/2022-April/640712.html). Also see [Buildroot 2022.02](http://lists.busybox.net/pipermail/buildroot/2022-March/638160.html)
  * [Erlang/OTP 25.0](https://erlang.org/download/OTP-25.0.README)

## v0.2.3

This release bumps Erlang to 24.3.2 and should be a low risk upgrade from the
previous release.

* Changes
  * Pull in upstream Linux SquashFS patch to improve file system performance
  * Switch back to using kernel modules for WiFi drivers to avoid needing to
    build regulatory information into the kernel.

* Updated dependencies
  * [nerves_system_br v1.18.6](https://github.com/nerves-project/nerves_system_br/releases/tag/v1.18.6)

## v0.2.2

* Changes
  * Enable the `ramoops` driver to capture log messages right before an
    unexpected reboot.
  * Turn off unused kernel options and adjust for faster boot times and smaller
    images.

## v0.2.1

This release has various Linux device tree and option updates to bootup warnings
and allow more hardware to be accessed in Elixir.

* Changes
  * Use the serial number printed on the GRiSP board

* Updated dependencies
  * [nerves_system_br v1.18.5](https://github.com/nerves-project/nerves_system_br/releases/tag/v1.18.5)

## v0.2.0

This is a very early port to the GRiSP2. It runs off eMMC, supports A/B firmware
updates like other Nerves devices, and basics like WiFi look like they work.

* Dependencies
  * [nerves_system_br v1.18.4](https://github.com/nerves-project/nerves_system_br/releases/tag/v1.18.4)
  * Erlang 24.2.1
  * Linux 5.10.76 with PHYTEC kernel patches

## v0.1.0

* Dependencies
  * [nerves_system_br v1.7.1](https://github.com/nerves-project/nerves_system_br/releases/tag/v1.7.1)
  * Erlang 21.2.7
  * Linux 4.14.93 with PHYTEC kernel patches
