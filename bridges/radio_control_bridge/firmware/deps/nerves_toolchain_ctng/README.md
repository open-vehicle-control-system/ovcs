# nerves-toolchain

This project contains the configuration and scripts used to build the
cross-compilers for the Nerves project. While pre-built toolchains exist for
various hosts and targets, they don't seem to exist for the combination
supported by Nerves. This project fills that gap.

See the GitHub `Releases` tab to download the toolchain. The naming for
toolchains is:

    nerves-toolchain-<gcc tuple>-<host OS>-<host architecture>-<version>.tar.xz

The `gcc tuple` is a standard way of describing a target. The most important parts
are the architecture (e.g., `arm`) and the C Library and ABI (e.g.,
`gnueabihf`). You will receive an error from Nerves if you mix toolchains. The
easy way to decide which toolchain you need is the following:

  * Raspberry Pi Model A+, B, or B+ - `armv6-nerves-linux-gnueabihf`
  * Raspberry Pi 2, BBB, and most other ARM boards - `armv7-nerves-linux-gnueabihf`

The `host OS` and `host architecture` describe your system. If you're running on
a Mac, this is `Darwin-x86_64` or `Darwin-arm64`.

When in doubt, use the glibc library toolchains. Almost all code works with the
glibc C library. If you desire the smallest possible target binaries, the musl
toolchain is the way to go. Nerves has been lightly tested against it, but it is
an experimental feature and not built by default due to issues on OSX.

## Linux

Install the following packages:

```sh
sudo apt install build-essential bison flex gperf libncurses5-dev texinfo help2man libssl-dev gawk libtool-bin automake lzip unzip python3 wget curl ca-certificates
```

Run `build_release.sh` and wait.

## OSX

Install the following packages:

```sh
brew update
brew install gawk binutils xz wget automake gnu-tar help2man bash make ncurses libtool autoconf gnu-sed mpfr gmp gcc bison lzip python3 grep coreutils texinfo
```

Run `build_release.sh` and wait.

## Windows

### Windows toolchains are not supported yet

Install [Chocolatey](https://chocolatey.org/). Then, from a command prompt with
administrative privileges (not the same one that you installed Chocolatey), run:

```sh
choco install cyg-get
cyg-get autoconf make gcc-g++ gperf bison flex texinfo awk wget curl patch libtool automake diffutils libncurses-devel help2man libssl-dev ca-certificates
cyg-get mingw64-i686-gcc-g++ mingw64-x86_64-gcc-g++ #??
```

Enable case-sensitive filesystem support on NTFS using the registry: (https://cygwin.com/cygwin-ug-net/using-specialnames.html)

```text
HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\kernel\obcaseinsensitive=0
```

Then tell Cygwin to mount your `cygdrive` as case sensitive. In a Cygwin64 terminal,
edit `/etc/fstab` and set `posix=1` in the mount options. For example:

```text
none /cygdrive cygdrive binary,posix=1,user 0 0
```

Something didn't work for me when downloading the ca-certificates. This will cause
https downloads to fail. To fix, here's what I did:

```sh
rm /usr/ssl/certs/ca-bundle.crt
ln -s /etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem /usr/ssl/certs/ca-bundle.crt
echo "ca_directory = /usr/ssl/certs" > ~/.wgetrc
```

Reboot to make the registry change take effect.

NOTE: Windows is a work in progress. The link step segfaults. The following
[doc](https://github.com/crosstool-ng/crosstool-ng/blob/main/docs/C%20-%20Misc.%20tutorials.txt)
may provide some help.

## Updating ctng config files

You may need to update the `ctng` configurations if `gcc` needs to be upgraded
or the C library needs to change. The small defconfigs are stored in the
`configs` directory and expanded automatically by `build.sh` to
`work-.../build/.config`. In that directory, you can run `make menuconfig` to
change the `ctng` configuration. When you're done, run `make savedefconfig` and
copy the result to the `configs` directory.

## Toolchain configuration notes

### Hard float vs. soft float

When possible hard float ABI (`eabihf`) toolchains are preferred. This appears to be
the prevaling preference for ARM toolchains, so in the offchance that we need to
run code from a binary blob, this provides the best chance of success. For ARM
processors that don't have hardware floating point instructions, use the `eabi`
versions of the ARM toolchain.

### Glibc 2.22 / Raspberry Pi userland

Glibc 2.22 has a `#define` change that breaks the Raspberry Pi userland
(rpi-userland) package. You'll get an error that `EAI_AGAIN` and some other
defines are missing due to a `#ifdef` that changed from `__USE_POSIX` to
`_USE_XOPEN2K`. Do *NOT* select glibc 2.22 until `rpi-userland` is fixed.

See https://bugs.busybox.net/show_bug.cgi?id=8446 for more details.

### Case insensitive filesystems

By default, the filesystems used on OSX are case insensitive. To get around
this, we create a case-sensitive filesystem and build the cross-compilers in it.
The build products also require a case-sensitive filesystem IF the user wants to
use the Linux netfilter module. This is currently not a common use case for
Nerves so the header file conflicts are removed in the OSX tarball version. See
`build.sh` for details.

## License

For the most part this code contains configurations and automates calls to other
projects, notably crosstool-ng. The `build.sh` script is licensed under the
Apache 2 License. Please see the numerous integrated projects for their
licenses.

`scripts/apply-patches.sh` is from the Buildroot project and is released under the
GNU General Public License, version 2 or later.
