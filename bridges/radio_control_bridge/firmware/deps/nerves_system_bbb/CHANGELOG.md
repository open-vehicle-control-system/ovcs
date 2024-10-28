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

## v2.24.0

This reverts the Linux kernel to 5.10.168. It was done to fix issues with eMMC
life time and the Ethernet PHY. See [PR #351](https://github.com/nerves-project/nerves_system_bbb/pull/351)
for details.

* Changes
  * Enable QMI kernel modules to support many cellular modems without a Nerves
    system update

* Updated dependencies
  * Linux 5.10.168 (TI patches 5.10.168-ti-r72)
  * [nerves_system_br v1.28.3](https://github.com/nerves-project/nerves_system_br/releases/tag/v1.28.3)
  * [Buildroot 2024.05.2](https://lore.kernel.org/buildroot/87zfpfh147.fsf@dell.be.48ers.dk/T/)
  * [Erlang/OTP 27.0.1](https://erlang.org/download/OTP-27.0.1.README)

## v2.23.0

This is a major Erlang and Buildroot update.

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
  * Linux 6.6.32 (TI patches 6.6.32-ti-arm32-r6)
  * [nerves_system_br v1.28.1](https://github.com/nerves-project/nerves_system_br/releases/tag/v1.28.1)
  * [Buildroot 2024.05](https://lore.kernel.org/buildroot/87bk46tjk2.fsf@dell.be.48ers.dk/T/)
  * [Erlang/OTP 27.0](https://erlang.org/download/OTP-27.0.README)

## v2.22.1

This is a security/bug fix update.

* Changes
  * Enable the `wpa_supplicant` option for allow wired 802.1x authentication

* Package updates
  * [Erlang/OTP 26.2.5](https://erlang.org/download/OTP-26.2.5.README)
  * [Buildroot 2024.02.1](https://lore.kernel.org/buildroot/87jzlp9u5e.fsf@48ers.dk/T/)

## v2.22.0

This is a major Buildroot update.

Please see the [nerves_system_br v1.27.0 release notes](https://github.com/nerves-project/nerves_system_br/releases/tag/v1.26.0)
for upgrade instructions if you've forked this system.

* Updated dependencies
  * Linux 6.6.15-ti-arm32-r1
  * [nerves_system_br v1.27.0](https://github.com/nerves-project/nerves_system_br/releases/tag/v1.27.0)
  * [Buildroot 2024.02](https://lore.kernel.org/buildroot/87msrczp4z.fsf@48ers.dk/)
  * [Erlang/OTP 26.2.3](https://erlang.org/download/OTP-26.2.3.README)

## v2.21.0

This is a major Buildroot and Linux update. If you use `circuits_gpio`, it is
critical to update to 1.2.0 or later to get a workaround for GPIO indices
changing.

Please see the [nerves_system_br v1.26.0 release notes](https://github.com/nerves-project/nerves_system_br/releases/tag/v1.26.0)
for upgrade instructions if you've forked this system.

* Updated dependencies
  * linux 6.1.69-ti-r21
  * [Erlang/OTP 26.2.2](https://erlang.org/download/OTP-26.2.2.README)
  * [nerves_system_br v1.26.1](https://github.com/nerves-project/nerves_system_br/releases/tag/v1.26.1)
  * [Buildroot 2023.11.1](https://lore.kernel.org/buildroot/87cyu2k2gu.fsf@48ers.dk/T/)

## v2.20.2

This is a security/bug fix update.

*  Package updates
  * [Erlang/OTP 26.2.1](https://erlang.org/download/OTP-26.2.1.README)
  * [nerves_heart 2.3.0](https://github.com/nerves-project/nerves_heart/releases/tag/v2.3.0)

## v2.20.1

This fixes a regression where the forced `circuits_gpio` dependency update broke
compilation. This removes the optional dependency, but be sure to see the note
below about the GPIOs being remapped and Circuits.GPIO v1.2.0 containing a
workaround.

## v2.20.0

This is a major Buildroot, toolchain, and Linux kernel update.

Please see [nerves_system_br v1.25.0 release notes](https://github.com/nerves-project/nerves_system_br/releases/tag/v1.25.0)
for upgrade instructions if you've forked this system.

The Linux kernel update from 5.10 to 6.1 has a side effect of renumbering GPIOs.
Circuits.GPIO v1.2 accounts for this so programs don't need to change that use
it. See https://github.com/elixir-circuits/circuits_gpio/pull/153 for more
information. This system has an optional dependency on Circuits.GPIO to force
the upgrade.

* Updated dependencies
  * Linux 6.1.46-ti-r13
  * [nerves_system_br v1.25.2](https://github.com/nerves-project/nerves_system_br/releases/tag/v1.25.2)
  * [Buildroot 2023.08.4](https://lore.kernel.org/buildroot/87o7f6t7fs.fsf@48ers.dk/T/)
  * [Erlang/OTP 26.1.2](https://erlang.org/download/OTP-26.1.2.README)

## v2.19.1

This is a security/bug fix update.

* Package updates
  * [nerves_system_br v1.24.1](https://github.com/nerves-project/nerves_system_br/releases/tag/v1.24.1)
  * [Erlang/OTP 26.1.1](https://erlang.org/download/OTP-26.1.1.README)
  * [Buildroot 2023.05.3](https://lore.kernel.org/buildroot/87h6ngup34.fsf@48ers.dk/T/)

## v2.19.0

This is a Buildroot version update that appears to mostly contain bug and
security fixes. It should be a low risk upgrade from v2.18.2.

* New features
  * Support factory reset, preventing firmware reverts. See [Nerves.Runtime.FwupOps](https://hexdocs.pm/nerves_runtime/Nerves.Runtime.FwupOps.html)

* Updated dependencies
  * [nerves_system_br v1.24.0](https://github.com/nerves-project/nerves_system_br/releases/tag/v1.24.0)
  * [Buildroot 2023.05.2](https://lore.kernel.org/buildroot/87ledrkrpp.fsf@48ers.dk/T/), [2023.05.1](https://lore.kernel.org/buildroot/87351m8qm4.fsf@48ers.dk/T/), [2023.05](https://lore.kernel.org/buildroot/87r0qn2c77.fsf@48ers.dk/T/)
  * [Erlang/OTP 26.1](https://erlang.org/download/OTP-26.1.README)

## v2.18.2

* Updated dependencies
  * [nerves_system_br v1.23.3](https://github.com/nerves-project/nerves_system_br/releases/tag/v1.23.3)

## v2.18.1

This is a bug and security fix update. It should be a low risk upgrade.

* Fixes
  * Fix CTRL+R over ssh

* Updated dependencies
  * [nerves_system_br v1.23.2](https://github.com/nerves-project/nerves_system_br/releases/tag/v1.23.2)
  * [Buildroot 2023.02.2](https://lore.kernel.org/buildroot/87y1je6wva.fsf@48ers.dk/T/)

## v2.18.0

This is a major update that brings in Erlang/OTP 26, Buildroot 2023.02.2 and
Linux 5.10.162.

* New features
  * CA certificates are included for OTP 26.

* Updated dependencies
  * [nerves_system_br v1.23.1](https://github.com/nerves-project/nerves_system_br/releases/tag/v1.23.1)
  * [Buildroot 2023.02.2](https://lore.kernel.org/buildroot/87wn03ifbl.fsf@48ers.dk/T/)
  * [Erlang/OTP 26.0.2](https://erlang.org/download/OTP-26.0.2.README)
  * Linux 5.10.162

## v2.17.2

This is a bug and security fix update. It should be a low risk upgrade.

* Updated dependencies
  * [nerves_system_br v1.22.5](https://github.com/nerves-project/nerves_system_br/releases/tag/v1.22.5)
  * [Buildroot 2022.11.3](https://lore.kernel.org/buildroot/878rfuxbxx.fsf@dell.be.48ers.dk/T/)

## v2.17.1

This is a bug fix and Erlang version bump from 25.2 to 25.2.3. It should be a
low risk upgrade.

* Fixes
  * Set Erlang crash dump timer to 5 seconds, so if an Erlang crash dump does
    happen, it will run for at most 5 seconds. See erlinit.conf.

* Updated dependencies
  * [nerves_system_br v1.22.3](https://github.com/nerves-project/nerves_system_br/releases/tag/v1.22.3)
  * [Buildroot 2022.11.1](https://lore.kernel.org/buildroot/87ilh4dvax.fsf@dell.be.48ers.dk/T/#u)

## v2.17.0

This is a Buildroot version update that appears to mostly contain bug and
security fixes. It should be a low risk upgrade.

* Updated dependencies
  * [nerves_system_br v1.22.1](https://github.com/nerves-project/nerves_system_br/releases/tag/v1.22.1)
  * [Buildroot 2022.11](http://lists.busybox.net/pipermail/buildroot/2022-December/656980.html)
  * GCC 12.2

## v2.16.2

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

## v2.16.1

* Changes
  * Reduce first-time Linux kernel download by using tarball source

* Updated dependencies
  * [nerves_system_br v1.21.2](https://github.com/nerves-project/nerves_system_br/releases/tag/v1.21.2)
  * [Erlang/OTP 25.1.2](https://erlang.org/download/OTP-25.1.2.README)

## v2.16.0

* Changes
  * Support aarch64 Linux builds
  * Add libdtc to support runtime loading of device tree overlays

* Updated dependencies
  * [nerves_system_br v1.21.1](https://github.com/nerves-project/nerves_system_br/releases/tag/v1.21.1)
    and also see [nerves_system_br v1.21.0](https://github.com/nerves-project/nerves_system_br/releases/tag/v1.21.0)
  * [Buildroot 2022.08.1](http://lists.busybox.net/pipermail/buildroot/2022-October/652816.html)
  * [Erlang/OTP 25.1.1](https://erlang.org/download/OTP-25.1.1.README)

## v2.15.3

* Fixes
  * Allow kernel includes for device tree overlays (Thanks @insasec)

* Updated dependencies
  * [nerves_system_br v1.20.6](https://github.com/nerves-project/nerves_system_br/releases/tag/v1.20.6)
  * [Erlang/OTP 25.0.4](https://erlang.org/download/OTP-25.0.4.README)
  * [Buildroot 2022.05.2](http://lists.busybox.net/pipermail/buildroot/2022-August/650546.html)
  * Also see [Buildroot 2022.05.1 changes](http://lists.busybox.net/pipermail/buildroot/2022-July/647814.html)

## v2.15.2

* Updated dependencies
  * [nerves_system_br v1.20.4](https://github.com/nerves-project/nerves_system_br/releases/tag/v1.20.4)
  * [Erlang/OTP 25.0.3](https://erlang.org/download/OTP-25.0.3.README)

## v2.15.1

This release reverts the upgrade to Linux 5.15.44. The Linux kernel is now at
5.10.120. This fixes an issue where the numbering of `/dev/gpiochipN` changed.
All code that identified GPIOs by number broke (pretty much everything using
Circuits.GPIO).

## v2.15.0

This release updates to Buildroot 2022.05, Linux 5.15.44 (from Linux 5.10) and
uses GCC 11.3 (from GCC 10.3). The Linux kernel upgrade could introduce a
regression, so please verify hardware-specific functionality in your firmware.

* Updated dependencies
  * [nerves_system_br v1.20.3](https://github.com/nerves-project/nerves_system_br/releases/tag/v1.20.3)
  * [Buildroot 2022.05](http://lists.busybox.net/pipermail/buildroot/2022-June/644349.html)
  * [Erlang/OTP 25.0.2](https://erlang.org/download/OTP-25.0.2.README)

## v2.14.0

This release updates to Buildroot 2022.02.1 and OTP 25.0. While this should be
an easy update for most projects, many programs have been updated. Please review
the changes in the updated dependencies for details.

* Updated dependencies
  * [nerves_system_br v1.19.0](https://github.com/nerves-project/nerves_system_br/releases/tag/v1.19.0)
  * [Buildroot 2022.02.1](http://lists.busybox.net/pipermail/buildroot/2022-April/640712.html). Also see [Buildroot 2022.02](http://lists.busybox.net/pipermail/buildroot/2022-March/638160.html)
  * [Erlang/OTP 25.0](https://erlang.org/download/OTP-25.0.README)

## v2.13.4

* Changes
  * Fix USB/Ethernet support on the BeagleBone Green Gateway
  * Fix regression in v2.13.3 for loading device tree overlays
  * Pull in upstream Linux SquashFS patch to improve file system performance

* Updated dependencies
  * [nerves_system_br v1.18.6](https://github.com/nerves-project/nerves_system_br/releases/tag/v1.18.6)
  * linux 5.10.100

## v2.13.3

This is mostly a Buildroot and Erlang bug and security fix release. It should be
a low risk upgrade from the previous release.

* Changes
  * Update the U-Boot bootloader to the 2021.10 release and pull in latest
    upstream Beaglebone patch set. This adds support for the BBG Gateway. Since
    the bootloader isn't normally updated, you'll need to re-flash the MicroSD
    card to get this update. If your device already works, then there's no
    reason to do this.

* Updated dependencies
  * [nerves_system_br v1.18.5](https://github.com/nerves-project/nerves_system_br/releases/tag/v1.18.5)
  * U-Boot 2021.10

## v2.13.2

This is a Buildroot and Erlang bug fix release that also adds support for
additional AM335x-based boards. It should be a low risk upgrade from the
previous release.

* Updated dependencies
  * [nerves_system_br v1.18.4](https://github.com/nerves-project/nerves_system_br/releases/tag/v1.18.4)
  * Linux 5.10.87

* Changes
  * Support the Beaglebone Blue (robotics-focused Beaglebone) and the AM3358 EVM
    Starter Kit (dual Ethernet)
  * Adjust PRU parameters to match TI configs. If you're using the PRUs, please
    verify that the changes do not break your code.
  * Reduce kernel timers from 250 Hz to 100 Hz resolution. 100 Hz is the value
    used by the TI source and the value used by other official Nerves systems.
  * When deriving the board serial number, fail back to the `/proc/cpuinfo`
    contents before using the wired Ethernet MAC.
  * Specify CPU-specific flags when compiling NIFs and ports. This fixes an
    issue where some optimizations could not be enabled in NIFs even though it
    should be possible to have them. E.g., ARM NEON support for CPUs that have
    it.
  * Build the Wireguard kernel driver. This is a small device driver that
    enables a number of VPN-based use cases.

## v2.13.1

* Updated dependencies
  * [nerves_system_br v1.18.3](https://github.com/nerves-project/nerves_system_br/releases/tag/v1.18.3)

* Changes
  * Programs that use OpenMP will run now. The OpenMP shared library
    (`libgomp.so`) was supplied by the toolchain, but not copied.

## v2.13.0

This release updates to Buildroot 2021.11, OTP 24.2, and Linux 5.10.64. If you
have made a custom system, please review the `nerves_system_br` [release
notes](https://github.com/nerves-project/nerves_system_br/blob/v1.18.2/CHANGELOG.md#v1180).
Also, the previous release used Linux 5.4, so double check your Linux
configuration to make sure that the update to Linux 5.10.64 doesn't disable
something unexpected.

* Updated dependencies
  * [nerves_system_br v1.18.2](https://github.com/nerves-project/nerves_system_br/releases/tag/v1.18.2)
  * [Buildroot 2021.11](http://lists.busybox.net/pipermail/buildroot/2021-December/629911.html)
  * [Erlang/OTP 24.2](https://erlang.org/download/OTP-24.2.README)
  * Linux 5.10.65 with RCN's TI patches. This formerly was the Beagleboard org's
    patch set. This should not affect most users.
  * GCC 10.3

* Improvements
  * Support for the `dl.nerves-project.org` backup site. Due to a GitHub outage
    in November, there was a 2 day period of failing builds since some packages
    could not be downloaded. We implemented the backup site to prevent this in
    the future. This update is in the `nerves_defconfig`.
  * Use new build ORB on CircleCI. This ORB will shorten build times to fit in
    CircleCI's new free tier limits. Please update if building your own systems.

## v2.12.3

* Updated dependencies
  * [nerves_system_br v1.17.4](https://github.com/nerves-project/nerves_system_br/releases/tag/v1.17.4)
  * [Buildroot 2021.08.2](http://lists.busybox.net/pipermail/buildroot/2021-November/628323.html)
  * [Erlang/OTP 24.1.7](https://erlang.org/download/OTP-24.1.7.README).

## v2.12.2

* Updated dependencies
  * [nerves_system_br v1.17.3](https://github.com/nerves-project/nerves_system_br/releases/tag/v1.17.3)
  * [Erlang/OTP 24.1.4](https://erlang.org/download/OTP-24.1.4.README).

## v2.12.1

This is a security/bug fix patch release. It should be safe to update for
everyone.

* Updated dependencies
  * [nerves_system_br v1.17.1](https://github.com/nerves-project/nerves_system_br/releases/tag/v1.17.1)
  * [Buildroot 2021.08.1](http://lists.busybox.net/pipermail/buildroot/2021-October/625642.html)
  * [Erlang/OTP 24.1.2](https://erlang.org/download/OTP-24.1.2.README)

* Improvements
  * Include software versioning and licensing info (see legal-info directory in
    artifact)

## v2.12.0

This release updates to Buildroot 2021.08 and OTP 24.1. If you have made a
custom system off this one, please review the `nerves_system_br v1.17.0` release
notes.
* Updated dependencies
  * [nerves_system_br v1.17.0](https://github.com/nerves-project/nerves_system_br/releases/tag/v1.17.0)
  * [Buildroot 2021.08](http://lists.busybox.net/pipermail/buildroot/2021-September/622072.html)
  * [Erlang/OTP 24.1](https://erlang.org/download/OTP-24.1.README)

## v2.11.2

This release updates Erlang/OTP from 24.0.3 to 24.0.5 and Buildroot from 2021.05
to 2021.05.1. Both of these are security/bug fix updates. This is expected to be
a safe upgrade from v1.16.1 for all users.

* Updated dependencies
  * [nerves_system_br v1.16.4](https://github.com/nerves-project/nerves_system_br/releases/tag/v1.16.1)
  * [Erlang/OTP 24.0.5](https://erlang.org/download/OTP-24.0.5.README)

* Improvements
  * Beta support for using a `runtime.exs` script for runtime configuration.
  * Added a `provision` task to the `fwup.config` to enable re-provisioning a
    MicroSD card without changing its contents.
  * Adds a default `/etc/sysctl.conf` that enables use of ICMP in Erlang. This
    requires `nerves_runtime v0.11.5` or later to automatically load the sysctl
    variables. With it using `:gen_udp` to send/receive ICMP will "just work".
    It also makes it easier to add other sysctl variables if needed.

## v2.11.1

This release updates Nerves Toolchains to v1.4.3 and OTP 24.0.3. It should be safe for everyone to apply.

* Updated dependencies
  * [nerves_system_br v1.16.1](https://github.com/nerves-project/nerves_system_br/releases/tag/v1.16.1)
  * [Erlang/OTP 24.0.3](https://erlang.org/download/OTP-24.0.3.README)
  * [nerves toolchains v1.4.3](https://github.com/nerves-project/toolchains/releases/tag/v1.4.3)
* Improvements
  * bborg-overlays: bump to latest SHA (device tree updates for BBB)

## v2.11.0

This release updates to Buildroot 2021.05 and OTP 24.0.2. If you have made a
custom system off this one, please review the `nerves_system_br v1.16.0` release
notes.

* Updated dependencies
  * [nerves_system_br v1.16.0](https://github.com/nerves-project/nerves_system_br/releases/tag/v1.16.0)
  * [Buildroot 2021.05](http://lists.busybox.net/pipermail/buildroot/2021-June/311946.html)
  * [Erlang/OTP 24.0.2](https://erlang.org/download/OTP-24.0.2.README)

* Improvements
  * This release now contains debug symbols and includes the Build-ID in the
    ELF headers. This makes it easier to get stack traces from C programs. As
    before, the Nerves tooling strips all symbols from firmware images, so this
    won't make programs bigger.
  * Enable compile-time `wpa_supplicant` options to support WPA3, mesh
    networking, WPS and autoscan.

## v2.10.1

This is a security/bug fix release that updates to Buildroot 2021.02.1 and OTP
23.3.1. It should be safe for everyone to apply.

* Updated dependencies
  * [nerves_system_br v1.15.1](https://github.com/nerves-project/nerves_system_br/releases/tag/v1.15.1)
  * [Buildroot 2021.02](http://lists.busybox.net/pipermail/buildroot/2021-April/307970.html)
  * [Erlang/OTP 23.3.1](https://erlang.org/download/OTP-23.3.1.README)

## v2.10.0

This release updates to Buildroot 2021.02 and OTP 23.2.7. If you have made a
custom system off this one, please review the `nerves_system_br v1.15.0` release
notes.

The Nerves toolchain has also been updated to v1.4.2. This brings in Linux 4.14
headers to enable use of cdev and eBPF. This won't affect most users.

* Updated dependencies
  * [nerves_system_br v1.15.0](https://github.com/nerves-project/nerves_system_br/releases/tag/v1.15.0)
  * [Buildroot 2021.02](http://lists.busybox.net/pipermail/buildroot/2021-March/305168.html)
  * [Erlang/OTP 23.2.7](https://erlang.org/download/OTP-23.2.7.README)
  * [nerves toolchains v1.4.2](https://github.com/nerves-project/toolchains/releases/tag/v1.4.2)

## v2.9.0

This release updates to Buildroot 2020.11.2, GCC 10.2 and OTP 23.2.4.

When migrating custom systems based, please be aware of the following important
changes:

* There's a new `getrandom` syscall that is made early in BEAM startup. This has
  the potential to block the BEAM before Nerves can start `rngd` to provide
  entropy. We have not seen this issue here, but have updated `erlinit.config`
  for the time being as a precaution.
* The GCC 10.2.0 toolchain has a different name that calls out "nerves" as the
  vendor and the naming is now more consistent with other toolchain providers.
* Experimental support for tooling that requires more information about the
  target has been added. The initial support focuses on zigler.

* Updated dependencies
  * [nerves_system_br: bump to v1.14.4](https://github.com/nerves-project/nerves_system_br/releases/tag/v1.14.4)
  * [Buildroot 2020.11.2](http://lists.busybox.net/pipermail/buildroot/2021-January/302574.html)
  * [Erlang/OTP 23.2.4](https://erlang.org/download/OTP-23.2.4.README)
  * [Nerves toolchains 1.4.1](https://github.com/nerves-project/toolchains/releases/tag/v1.4.1)

## v2.8.3

This is a bug fix release with no major changes.

* Updated dependencies
  * [nerves_system_br: bump to v1.13.7](https://github.com/nerves-project/nerves_system_br/releases/tag/v1.13.7)
  * [Erlang/OTP 23.1.5](https://erlang.org/download/OTP-23.1.5.README)

## v2.8.2

This release includes a patch release update to [Buildroot
2020.08.2](http://lists.busybox.net/pipermail/buildroot/2020-November/296830.html).

* Updated dependencies
  * [nerves_system_br: bump to v1.13.5](https://github.com/nerves-project/nerves_system_br/releases/tag/v1.13.5)
  * [erlinit 1.9.0](https://github.com/nerves-project/erlinit/releases/tag/v1.9.0)

## v2.8.1

The main change in this release is to bump the Linux kernel to 5.4.
If you have based a custom system off of this one, please inspect the
`linux-5.4.defconfig` for changes. There were only a few changes, but
if you are modifying the kernel configuration, please review first.

* Updated dependencies
  * [nerves_system_br: bump to v1.13.4](https://github.com/nerves-project/nerves_system_br/releases/tag/v1.13.4)
  * [Erlang/OTP 23.1.4](https://erlang.org/download/OTP-23.1.4.README)
  * [boardid 1.10.0](https://github.com/nerves-project/boardid/releases/tag/v1.10.0)

* Improvements
  * Enabled reproducible builds in Buildroot to remove some timestamp and build
    path differences in firmware images. This helps delta firmware updates.

## v2.8.0

This release updates to [Buildroot
2020.08](http://lists.busybox.net/pipermail/buildroot/2020-September/290797.html) and OTP 23.1.1.

* Updated dependencies
  * [nerves_system_br: bump to v1.13.2](https://github.com/nerves-project/nerves_system_br/releases/tag/v1.13.2)
  * [Erlang/OTP 23.1.1](https://erlang.org/download/OTP-23.1.1.README)
  * [erlinit 1.8.0](https://github.com/nerves-project/erlinit/releases/tag/v1.8.0)
  * [nerves 1.7.0](https://github.com/nerves-project/nerves/releases/tag/v1.7.0)

* New features
  * Added support for updating the root filesystem using firmware patches.
    See the [firmware patch docs](https://hexdocs.pm/nerves/experimental-features.html#content) for more information.

## v2.7.2

This release updates to [Buildroot
2020.05.1](http://lists.busybox.net/pipermail/buildroot/2020-July/287824.html)
and OTP 23.0.3 which are both bug fix releases.

* Updated dependencies
  * [nerves_system_br: bump to v1.12.4](https://github.com/nerves-project/nerves_system_br/releases/tag/v1.12.4)
  * [Erlang/OTP 23.0.3](https://erlang.org/download/OTP-23.0.3.README)
  * [nerves_heart v0.3.0](https://github.com/nerves-project/nerves_heart/releases/tag/v0.3.0)

* New features
  * The `/data` directory now exists for storing application-specific data. It
    is currently a symlink to `/root`. Using `/data` will eventually be
    encouraged over `/root` even though currently there is no advantage. This
    change makes it possible to start migrating paths in applications and
    libraries.

* Fixes
  * Fixed old references to the `-Os` compiler flag. All C/C++ code will default
    to using `-O2` now.

## v2.7.1

* Fixes
  * Remove `nerves_system_linter` from hex package. This fixes mix dependency
    errors in projects that reference systems with different
    `nerves_system_linter` dependency specs.

## v2.7.0

This release updates the system to use Buildroot 2020.05 and Erlang/OTP 23.
Please see the respective release notes for updates and deprecations in both
projects for changes that may affect your application.

* New features
  * Enable WiFi mesh support in the 802.11 stack
  * NervesKey support (see README.md for device tree overlay information)

* Updated dependencies
  * [nerves_system_br v1.12.0](https://github.com/nerves-project/nerves_system_br/releases/tag/v1.12.0)
  * [Erlang/OTP 23.0.2](https://erlang.org/download/OTP-23.0.2.README)
  * Linux 4.19.120 with Beagleboard kernel patches

## v2.6.2

* Updated dependencies
  * [nerves_system_br v1.11.4](https://github.com/nerves-project/nerves_system_br/releases/tag/v1.11.4)
  * Erlang 22.3.4.1
  * fwup 1.7.0

## v2.6.1

* Updated dependencies
  * [nerves_system_br v1.11.2](https://github.com/nerves-project/nerves_system_br/releases/tag/v1.11.2)
  * Erlang 22.3.1
  * erlinit 1.7.0 - tty initialization support
  * fwup 1.6.0 - xdelta3/VCDIFF patch support
  * Enable unixodbc so that Erlang's odbc application can be used in projects

## v2.6.0

This release updates Buildroot to 2020.02 and upgrades gcc from 8.3 to 9.2.
While this is a minor version bump due to the Buildroot release update, barring
advanced usage of Nerves, this is a straightforward update from v2.5.2.

* Updated dependencies
  * [nerves_system_br v1.11.0](https://github.com/nerves-project/nerves_system_br/releases/tag/v1.11.0)
  * linux 4.19.103 with Beagleboard kernel patches(bone40)
  * Erlang 22.2.8

## v2.5.2

* Fixes
  * This fixes a regression on OSX where the USB gadget Ethernet would
    incorrectly try to go into RNDIS mode and not work. Gadget Ethernet works
    with this fix on Linux and OSX. It also works on Windows with a driver
    installed. See the README.md for details.
  * The USB driver uses PIO mode again. It had mistakenly been switched to DMA
    mode. DMA mode works for a lot of USB devices, but not all and it's not what
    Debian does. See [PR
    138](https://github.com/nerves-project/nerves_system_bbb/pull/138) for more
    information.

* Updated dependencies
  * [nerves_system_br v1.10.2](https://github.com/nerves-project/nerves_system_br/releases/tag/v1.10.2)
  * Erlang 22.2.4

## v2.5.1

This release changes the behavior of the gadget port. The gadget driver has been changed to use g_ether. This
provides a more stable network connection at the expense of the virtual serial
port.

* Enhancements
  * Set `expand=true` on the application data partition. This will only take
    effect for users running the complete task, fwup will not expand application
    data partitions that exist during upgrade tasks.
  * linux: swap the cdc composite gadget for g_ether

* Updated dependencies
  * [nerves_system_br v1.10.1](https://github.com/nerves-project/nerves_system_br/releases/tag/v1.10.1)
  * Erlang 22.2.3


## v2.5.0

This release updates Buildroot to 2019.11 with security and bug fix updates
across Linux packages. Enables dnsd, udhcpd and ifconfig in the default
Busybox configuration to support `vintage_net` and `vintage_net_wizard`.
See the `nerves_system_br` notes for details.

* Updated dependencies
  * [nerves_system_br v1.10.0](https://github.com/nerves-project/nerves_system_br/releases/tag/v1.10.0)
  * Erlang 22.1.8
  * Linux 4.19.72 with the Beagleboard Debian kernel patches

## v2.4.2

This release updates Buildroot to 2019.08.2 with security and bug fix updates
across Linux packages. See the `nerves_system_br` notes for details.
Erlang/OTP is now at 22.1.7.

This release also enables the pinmux helper for changing the pin settings on
the PocketBeagle and other boards.

For example:

```bash
iex> cat "/sys/devices/platform/ocp/ocp:P2_30_pinmux/state"
default
iex> File.write("/sys/devices/platform/ocp/ocp:P2_30_pinmux/state", "spi_cs")
:ok
```

For the PocketBeagle, see
https://github.com/beagleboard/linux/blob/4.19/arch/arm/boot/dts/am335x-pocketbeagle.dts#L1186

* Updated dependencies
  * [nerves_system_br v1.9.5](https://github.com/nerves-project/nerves_system_br/releases/tag/v1.9.5)

## v2.4.1

This release pulls in security and bug fix updates from `nerves_system_br`.
Erlang/OTP is now at 22.1.1.

* Updated dependencies
  * [nerves_system_br v1.9.4](https://github.com/nerves-project/nerves_system_br/releases/tag/v1.9.4)
  * bborg-overlays - update to latest to pull in device tree overlay fixes and
    additions from upstream

## v2.4.0

This release updates Buildroot to 2019.08 with security and bug fix updates
across Linux packages. See the `nerves_system_br` notes for details.

* Updated dependencies
  * [nerves_system_br v1.9.2](https://github.com/nerves-project/nerves_system_br/releases/tag/v1.9.2)

* Enhancements
  * Support a variety of USB->UART adapters so more devices work out-of-the-box

## v2.3.2

This release fixes an issue where the MAC address for the wired Ethernet port on
many BeagleBone-based boards was not being set. Unfortunately, the fix is with
the U-Boot bootloader configuration and this is not updated when applying
updates over-the-air. Fresh firmware installs will apply the fix, so if you're
burning MicroSD cards, you're fine. It is possible to fix the wired Ethernet MAC
address issue in the field if necessary. Please post to our support channels if
you need to do this and are not sure.

* Updated dependencies
  * [nerves_system_br v1.8.5](https://github.com/nerves-project/nerves_system_br/releases/tag/v1.8.5)
  * Linux 4.19.50

## v2.3.1

* Enhancements
  * Enable source-based routing in the Linux kernel to support [vintage_net](https://github.com/nerves-networking/vintage_net)
  * Enable pstore, an in-memory buffer that can capture logs, kernel
    oops and other information when unexpected reboots. The buffer can be
    recovered on the next boot where it can be inspected.

* Updated dependencies
  * [nerves_system_br v1.8.4](https://github.com/nerves-project/nerves_system_br/releases/tag/v1.8.4)

## v2.3.0

This release

This release updates Erlang to OTP 22 and gcc from version 7.3.0 to 8.3.0.
See the nerves_system_br and toolchain release notes for more information.

* Enhancements
  * Enable source-based routing in the Linux kernel to support [vintage_net](https://github.com/nerves-networking/vintage_net)

* Updated dependencies
  * Erlang 22.0.4
  * [nerves_system_br v1.8.2](https://github.com/nerves-project/nerves_system_br/releases/tag/v1.8.2)
  * [nerves_toolchain_arm_unknown_linux_gnueabihf v1.2.0](https://github.com/nerves-project/toolchains/releases/tag/v1.2.0)

## v2.2.2

* Bux fixes
  * Add TAR option `--no-same-owner` to fix errors when untarring artifacts as
    the root user.
* Updated dependencies
  * [nerves_system_br v1.7.2](https://github.com/nerves-project/nerves_system_br/releases/tag/v1.7.2)

## v2.2.1

* Bug fixes
  * Re-enabled Ralink rt2800usb WiFi driver.

* Improvements
  * Bump C compiler options to `-O2` from `-Os`. This provides a small, but
    measurable performance improvement (500ms at boot in a trivial project
    tested on [nerves_system_rpi0](https://github.com/nerves-project/nerves_system_rpi0)).
  * Added r8712u.ko WiFi driver.

* Updated dependencies
  * [nerves_system_br v1.7.1](https://github.com/nerves-project/nerves_system_br/releases/tag/v1.7.1)

## v2.2.0

 * Updated dependencies
  * [nerves_system_br v1.7.0](https://github.com/nerves-project/nerves_system_br/releases/tag/v1.7.0)
  * Erlang 21.2.7
  * Linux 4.19.26 with the Beagleboard Debian kernel patches

## v2.1.3

 * Updated dependencies
  * [nerves_system_br v1.6.8](https://github.com/nerves-project/nerves_system_br/releases/tag/v1.6.8)
  * Erlang 21.2.6

## v2.1.2

* Updated dependencies
  * [nerves_system_br v1.6.6](https://github.com/nerves-project/nerves_system_br/releases/tag/v1.6.6)
  * Erlang 21.2.4
  * boardid 1.5.3

## v2.1.1

* Updated dependencies
  * [nerves_system_br v1.6.5](https://github.com/nerves-project/nerves_system_br/releases/tag/v1.6.5)
  * Erlang 21.2.2
  * boardid 1.5.2
  * erlinit 1.4.9
  * OpenSSL 1.1.1a
  * Linux 4.19.10 with the Beagleboard Debian kernel patches

* Enhancements
  * Moved boardid config from inside erlinit.config to /etc/boardid.config

## v2.1.0

This pulls in a pending patch in Buildroot to update the version of
OpenSSL from 1.0.2 to 1.1.0h. This fixes what appears to be issues with
Erlang using OpenSSL engines. It also enables Erlang crypto algorithms
such as ed25519 that have been added in recent Erlang releases.

* Updated dependencies
  * [nerves_system_br v1.6.1](https://github.com/nerves-project/nerves_system_br/releases/tag/v1.6.1)
  * Erlang 21.2
* Added dependencies
  * wpa_passphrase
  * libp11 0.4.9

## v2.0.0

* Enhancements
  * Enable `AM335X-PRU-UIO-00A0` device tree overlay for PRU support.
    See the [README.md](https://github.com/nerves-project/nerves_system_bbb/README.md#prus) for more information.
* Updated dependencies
  * [nerves_system_br v1.5.3](https://github.com/nerves-project/nerves_system_br/releases/tag/v1.5.3)

## v2.0.0-rc.0

This is a backwards incompatible update to `nerves_system_bbb`. Over-the-air
updates to existing devices will not work. If you're a production user of
`nerves_system_bbb`, please consider supporting efforts to maintain a v1.4.0
branch.

The v2.0.0 support adds the following:

1. Device tree overlays are applied by U-Boot now. Support in Nerves is nearly
   identical to Beagleboard.org's Debian distribution. This fixes significant
   issues in v1.4.0 and before ever since upstream moved from loading device
   tree overlays in Linux to U-Boot.
2. Support for automatic failback of bad new builds. If enabled, your Nerves
   application will need to mark a software update as good (for example, it can
   contact a server) or else the next reboot will revert.
3. The application partition uses F2FS rather than EXT4. This noticeably
   improves startup time on the first boot and has some less obvious advantages
   from being a Flash-aware file system.
4. The hardware watchdog is enabled at boot. Your application must enable
   `heart` now.
5. The U-Boot environment was increased in size to 128 KB. This was required for
   the new device tree overlay support and unfortunately makes migrating devices
   from v1.4.0 not possible without significant work.


* Updated dependencies
  * [nerves_system_br v1.5.2](https://github.com/nerves-project/nerves_system_br/releases/tag/v1.5.2)
  * Linux 4.18.9 + The Beagleboard Debian kernel patches
  * Erlang 21.0.9

## v1.4.0

This release contains various updates to provisioning variables and data.

**Host requirements**

Building firmware using this system requires `fwup` to be updated on your
host computer to at least `v1.2.5`. The target minimum version requirement
has not changed from `0.15.0`.

**Serial numbers**

Device serial numbers are now set using `NERVES_SERIAL_NUMBER` instead of
`SERIAL_NUMBER`. This is to reduce ambiguity on the source of the serial
by name spacing it along side other Nerves variables. The U-Boot environment
key has also changed from `serial_number` to `nerves_serial_number`. The
erlinit.config has been updated to provide backwards compatibility for setting
the hostname from the serial number by checking for `nerves_serial_number`
and falling back to `serial_number`.

**Custom provisioning**

Provisioning data is applied at the time of calling the `fwup` task `complete`.
The `complete` task is executed when writing the firmware to the target disk.
During this time, `fwup` will include the contents of a provisioning file
located at `${NERVES_SYSTEM}/images/fwup_include/provisioning.conf`. By default,
this file only sets `nerves_serial_number`. You can add additional provisioning
data by overriding the location of this file to include your own by setting
the environment variable `NERVES_PROVISIONING`. If you override this variable
you will be responsible for also setting `nerves_serial_number`.

* Updated dependencies
  * [nerves_system_br v1.4.5](https://github.com/nerves-project/nerves_system_br/releases/tag/v1.4.5)

## v1.3.0

This release upgrades gcc from version 6.3.0 to 7.3.0. See the toolchain release
notes for more information.

Switch to using busybox.fragment for easier maintainance.

* Updated dependencies
  * [nerves_system_br v1.4.1](https://github.com/nerves-project/nerves_system_br/releases/tag/v1.4.1)
  * [nerves_toolchain_arm_unknown_linux_gnueabihf v1.1.0](https://github.com/nerves-project/toolchains/releases/tag/v1.1.0)

## v1.2.1

* Updated dependencies
  * [nerves_system_br v1.3.2](https://github.com/nerves-project/nerves_system_br/releases/tag/v1.3.2)

## v1.2.0

This release updates Erlang to OTP 21.0

* Updated dependencies
  * [nerves_system_br v1.3.0](https://github.com/nerves-project/nerves_system_br/releases/tag/v1.3.0)

## v1.1.1

This release fixes some issues and adds firmware UUID support. This support can
be used to unambiguously know what's running on a device.

* Updated dependencies
  * [nerves_system_br v1.2.2](https://github.com/nerves-project/nerves_system_br/releases/tag/v1.2.2)

* Bug fixes
  * Empty serial numbers stored in the U-Boot environment would be used instead
    of reverting to devices IDs built into the CPU or board.
  * It wasn't possible to enable QtWebEngine (needed for kiosk apps)

## v1.1.0

This release adds official support for provisioning serial numbers to devices.
Other information can be provisioned in a similar manner. See the README.md for
details.

Buildroot was also updated to 2018.05. Be sure to review the `nerves_system_br`
link for the changes in the embedded Linux components.

* Updated dependencies
  * [nerves_system_br v1.2.0](https://github.com/nerves-project/nerves_system_br/releases/tag/v1.2.0)

* New features
  * More `wpa-supplicant` features were enabled to support more WiFi use-cases

## v1.0.0

This release is nearly identical to rc.1 except with the deps bump to 1.0 and
documentation/comment updates.

* Updated dependencies
  * [nerves_system_br v1.0.0](https://github.com/nerves-project/nerves_system_br/releases/tag/v1.0.0)
  * [nerves_toolchain v1.0.0](https://github.com/nerves-project/toolchains/releases/tag/v1.0.0)
  * [nerves v1.0.0](https://github.com/nerves-project/nerves/releases/tag/1.0.0)

## v1.0.0-rc.1

This release contains updates to Erlang and heart from `nerves_system_br`. It
also has a configuration change to the Linux kernel that enables scaling the
processor frequency based on workload. This makes the process run much cooler
while still allowing it to increase frequency for heavy computations.

Note that the trivial `.fw` files are no longer created by CI scripts. If you've
forked this project and are building systems using CI, make sure to update your
publish scripts.

* Updated dependencies
  * [nerves_system_br v1.0.0-rc.2](https://github.com/nerves-project/nerves_system_br/releases/tag/v1.0.0-rc.2)
  * Linux 4.4.113 w/ RCN's patches

## v1.0.0-rc.0

* Updated dependencies
  * [nerves_system_br v1.0.0-rc.0](https://github.com/nerves-project/nerves_system_br/releases/tag/v1.0.0-rc.0)
  * [nerves_toolchain v1.0.0-rc.0](https://github.com/nerves-project/toolchains/releases/tag/v1.0.0-rc.0)
  * [nerves v1.0.0-rc.0](https://github.com/nerves-project/nerves/releases/tag/1.0.0-rc.0)

## v0.20.0

* Updated dependencies
  * [nerves_system_br v0.17.0](https://github.com/nerves-project/nerves_system_br/releases/tag/v0.17.0)
  * [nerves_toolchain v0.13.0](https://github.com/nerves-project/toolchains/releases/tag/v0.13.0)
  * [nerves v0.9.0](https://github.com/nerves-project/nerves/releases/tag/v0.9.0)

## v0.19.1

* Updated dependencies
  * [nerves_system_br v0.16.3](https://github.com/nerves-project/nerves_system_br/releases/tag/v0.16.3)
    This fixes the call to otp_build so that it always uses Buildroot's version
    the autoconf tools.

## v0.19.0

* Updated dependencies
  * [nerves_system_br v0.16.1-2017-11](https://github.com/nerves-project/nerves_system_br/releases/tag/v0.16.1-2017-11)

* Enhancements
  * Reboot automatically if Erlang VM exits - This is consistent with other
    Nerves systems. See rootfs_overlay/etc/erlinit.config if undesired.
  * Start running nerves_system_linter to check for configuration errors.
  * Automount the boot partition readonly at `/boot`
  * Support for reverting firmware.

    See [Reverting Firmware](https://hexdocs.pm/nerves_runtime/readme.html#reverting-firmware) for more info on reverting firmware.

    See [fwup-revert.conf](https://github.com/nerves-project/nerves_system_rpi/blob/master/fwup-revert.conf) for more information on how fwup handles reverting.

## v0.18.0

* Updated dependencies
  * [nerves_system_br v0.15.0](https://github.com/nerves-project/nerves_system_br/releases/tag/v0.15.0)
  * [toolchain v0.12.1](https://github.com/nerves-project/toolchains/releases/tag/v0.12.1)
  * u-boot 2017.09
  * Linux 4.4.91 w/ RCN's patches

* Enhancements
  * Support for nerves 0.8. Moves nerves.exs into mix.exs
  * Support for pocketbeagle

* Bug Fixes
  * Clear out the wl18xx MAC address field
    This will trigger the WiLink device driver to use the MAC address that
    TI programmed into the module rather than 00:00:de:ad:be:ef.

## v0.17.1

* Updated dependencies
  * [nerves_system_br v0.14.1](https://github.com/nerves-project/nerves_system_br/releases/tag/v0.14.1)

## v0.17.0

This release changes the default IEx prompt output from the debug UART pins
to a virtual serial port on the USB OTG connector. This release also enables
a virtual Ethernet interface on the same USB interface for software updates.
See the `nerves_init_gadget` project for initialization code.

* Updated dependencies
  * [nerves_system_br v0.14.0](https://github.com/nerves-project/nerves_system_br/releases/tag/v0.14.0)
    * [Buildroot 2017.08](https://git.busybox.net/buildroot/plain/CHANGES?id=2017.08)
    * [fwup 0.17.0](https://github.com/fhunleth/fwup/releases/tag/v0.17.0)
    * [erlinit 1.2.0](https://github.com/nerves-project/erlinit/releases/tag/v1.2.0)
    * [nbtty 0.3.0](https://github.com/fhunleth/nbtty/releases/tag/v0.3.0)

* Enhancements
  * Add global patch directory

  This is required to pull in the e2fsprogs patch that's needed now that
  util-linux's uuid_generate function calls getrandom and can block
  indefinitely for the urandom pool to initialize

* Bug Fixes
  * Use `nbtty` by default to fix tty hang issue

## v0.16.1

* Updated dependencies
  * nerves_system_br v0.13.7

## v0.16.0

This release contains an updated toolchain with Linux 4.1 Headers.
You will have to clean and compile any c/c++ code in your project and
dependencies. Failure to do so will result in an error when producing firmware.

* nerves_system_br v0.13.5
  * fwup 0.15.4

* Nerves toolchain v0.11.0

## v0.15.0

* nerves_system_br v0.13.3
  * erlinit 1.1.4

* New features
  * Firmware updates verify that they're updating the right target. If the target
    doesn't say that it's an `bbb` through the firmware metadata, the update
    will fail.
  * Added meta-misc and meta-vcs-identifier to the `fwup.conf` metadata for use
    by users and for the regression test framework
  * Use String.trim instead of String.strip to silence Elixir 1.5 warnings

## v0.14.0

* nerves_system_br v0.13.2
  * OTP 20
  * erlinit 1.1.3
  * fwup 0.15.3

## v0.13.0

This release is NOT backwards compatible with previous releases and will not
upgrade old systems. With work, it is possible to upgrade old systems, but it is
not recommended.

* nerves_system_br v0.12.1
  * erlinit 1.1.1
  * fwup 0.15.0

* New features
  * The application data partition is now `ext4`. This greatly improves its
    robustness to corruption. Nerves.Runtime contains code to initialize it on
    first boot.
  * Firmware images now contain metadata that can be queried at runtime (see
    Nerves.Runtime.KV
  * The boot partition is managed in an A/B style to support more robust
    firmware updates.

* Bug fixes
  * The Linux kernel is no longer compiled for SMP. All Beaglebone variants
    are single processor.

NOTE: It is possible to support "failback" operation of firmware updates with
the BBB. I.e. if an partition doesn't boot, the system reverts to the previous
one. This is not implemented here, but this system is being made to align more
with implementations that do this to make the transition easier.

## v0.12.0

* nerves_system_br v0.10.0
  * Buildroot 2017.02
  * Erlang/OTP 19.3

* New features
  * Support for BBG Wireless - the BBGW's MAC Address is not automatically set
    so support needs to be added. However, one BBGW on a WLAN works.
  * Bump Linux kernel to 4.4.60

## v0.11.0

* New Features
  * Support for Nerves 0.5.0

## v0.10.0

* New features
  * Bump toolchain to use gcc 5.3 (previously using gcc 4.9.3)
  * Bump Linux kernel to 4.4.43

## v0.9.0

This version switches to using the `nerves_package` compiler. This will
consolidate overall deps and compilers.

* Nerves.System.BR v0.8.1
  * Support for distillery
  * Support for nerves_package compiler

## v0.8.0

When upgrading to this version, be sure to review the updates to
nerves_defconfig. BR2_PACKAGE_ERLANG is no longer selected automatically and
must be added.

* nerves_system_br v0.7.0
  * Package updates
    * Buildroot 2016.08

  * Bug fixes
    * Many packages were removed. These include Elixir and LFE since neither are
      actually used. Both are added as part of the user build step, so no
      functionality is lost. The most visible result is that the system images
      are smaller and the test .fw file boots to the Erlang prompt.
    * Fix false positive from scrubber when checking executable formats due to
      C++ template instantiations. Ignores SYSV vs. GNU/Linux ABI difference.

## v0.7.1

* Package versions
  * Nerves.System.BR v0.6.1

* New features
  * Pull in BeagleBone Green updates (new u-boot, bbg device tree)

## v0.7.0

* Nerves.System.BR v0.6.0
  * Package updates
    * Erlang OTP 19
    * Elixir 1.3.1
    * fwup 0.8.0
    * erlinit 0.7.3
    * bborg-overlays (pull in I2C typo fix from upstream)
  * Bug fixes
    * Synchronize file system kernel configs across all platforms

## v0.6.2

* Bug Fixes
  * Enabled bbborg-overlays for universal device tree

## v0.6.1

* Nerves.System.BR v0.5.1
  * Bug Fixes(nerves-env)
    * Added include paths to CFLAGS and CXXFLAGS
    * Pass sysroot to LDFLAGS

## v0.6.0

* Nerves.System.BR v0.5.0
  * New features
    * WiFi drivers enabled by default on RPi2 and RPi3
    * Include wireless regulatory database in Linux kernel by default
      on WiFi-enabled platforms. Since kernel/rootfs are read-only and
      coupled together for firmware updates, the normal CRDA/udev approach
      isn't necessary.
    * Upgraded the default BeagleBone Black kernel from 3.8 to 4.4.9. The
      standard BBB device tree overlays are included by default even though the
      upstream kernel patches no longer include them.
    * Change all fwup configurations from two step upgrades to one step
      upgrades. If you used the base fwup.conf files to upgrade, you no
      longer need to finalize the upgrade. If not, there's no change.

## v0.5.0

* Nerves.System.BR v0.4.1
  * Bug fixes
    * syslinux fails to boot when compiled on some gcc 5 systems
    * Fixed regression when booting off eMMC on the BBB

  * Package updates
    * Erlang 18.3
    * Elixir 1.2.5
* Enhancements
  * Includes config-pin for controlling pin muxing. See [beaglebone-universal-io](https://github.com/cdsteinkuehler/beaglebone-universal-io)
