# NervesSSH

[![CircleCI](https://circleci.com/gh/nerves-project/nerves_ssh/tree/main.svg?style=svg)](https://circleci.com/gh/nerves-project/nerves_ssh/tree/main)
[![Hex version](https://img.shields.io/hexpm/v/nerves_ssh.svg "Hex version")](https://hex.pm/packages/nerves_ssh)

Manage an SSH daemon and its subsystems on Nerves devices. It has the following
features:

1. Automatic startup of the SSH daemon on initialization
2. Ability to hook the SSH daemon into a supervision tree of your choosing
3. Easy setup of SSH firmware updates for Nerves
4. Easy shell and exec setup for Erlang, Elixir, and LFE
5. Some protection from easy-to-make mistakes that would cause ssh to not be
   available

## Usage

This library wraps Erlang/OTP's [SSH
daemon](http://erlang.org/doc/man/ssh.html#daemon-1) to make it easier to use
reliably with Nerves devices.

Most importantly, it makes it possible to segment failures in other OTP
applications from terminating the daemon and it recovers from rare scenarios
where the daemon terminates without automatically restarting.

It can be started automatically as an OTP application or hooked into a
supervision tree of your creation. Most Nerves users start it automatically as
an OTP application. This is easy, but may be limiting and it requires that you
use the application environment. See the following sections for options:

### Starting as an OTP application

If you're using [`:nerves_pack`](https://hex.pm/packages/nerves_pack) v0.4.0 or
later, you don't need to do anything except verify the `:nerves_ssh`
configuration in your `config.exs` (see below). If you are not using
`:nerves_pack`, add `:nerves_ssh` to your `mix` dependency list:

```elixir
def deps do
  [
    {:nerves_ssh, "~> 0.1.0", targets: @all_targets}
  ]
end
```

And then include it in `:shoehorn`'s `:init` list:

```elixir
config :shoehorn,
  init: [:nerves_runtime, :vintage_net, :nerves_ssh]
```

`:nerves_ssh` will work if you do not add it to the `:init` list. However, if
your main OTP application stops, OTP may stop `:nerves_ssh`, and that would make
your device inaccessible via SSH.

### Starting as part of one of your supervision trees

If you want to do this, make sure that you do NOT specify `:nerves_ssh` in your
`config.exs`. The `:nerves_ssh` key decides whether or not to automatically launch
based on this.

Then when specifying the children for your supervisor, add `NervesSSH` like
this:

```elixir
    {NervesSSH, nerves_ssh_options}
```

The `nerves_ssh_options` should be a `NervesSSH.Options` struct. See the
`Configuration` section option fields that you may specify. Calling
`NervesSSH.Options.with_defaults(my_options_list)` to build the
`nerves_ssh_options` value is one way of getting reasonable defaults.

## Configuration

NervesSSH supports the following configuration items:

* `:authorized_keys` - a list of SSH authorized key file string
* `:user_passwords` - a list of username/password tuples (stored in the
    clear!)
* `:port` - the TCP port to use for the SSH daemon. Defaults to `22`.
* `:subsystems` - a list of [SSH subsystems specs](https://erlang.org/doc/man/ssh.html#type-subsystem_spec) to start.
  Defaults to SFTP and `ssh_subsystem_fwup`
* `:system_dir` - where to find host keys. Defaults to `"/data/nerves_ssh"`
* `:shell` - the language of the shell (`:elixir`, `:erlang`, `:lfe`,  or
  `:disabled`). Defaults to `:elixir`.
* `:exec` - the language to use for commands sent over ssh (`:elixir`,
  `:erlang`, `lfe`, or `:disabled`). Defaults to `:elixir`.
* `:iex_opts` - additional options to use when starting up IEx
* `:daemon_option_overrides` - additional options to pass to `:ssh.daemon/2`.
  These take precedence and are unchecked. Be careful using this since it can
  break other options.

### SSH host keys

SSH identifies itself to clients using a host key. Clients can record the key
and use it to detect man-in-the-middle attacks and other shenanigans on future
connections. Host keys are stored in the `:system_dir` (see configuration) and
named `ssh_host_rsa_key`, `ssh_host_ed25519_key`, etc.

NervesSSH will create a host key the first time it starts if one does not exist.
The key will be stored in `:system_dir`. Be aware that the host key is not
encrypted or protected so anyone with access to the device can get it if they
choose.

If the `:system_dir` is not writable, NervesSSH will create an in-memory host
key so that users can still log in. In fact, even if the file system is
writable, NervesSSH will verify the host key before using it and recreate it if
corrupt. The goal is that broken host keys to not result in a situation where
it's impossible to log into a device. Your SSH client complaining about the host
key changing will be the hint that something is wrong.

NervesSSH currently supports
[Ed25519](https://en.wikipedia.org/wiki/EdDSA#Ed25519) and
[RSA](https://en.wikipedia.org/wiki/RSA_(cryptosystem)) host keys.

If you rewrite your MicroSD cards often and don't want to get SSH client errors,
add the following to your `~/.ssh/config`:

```sshconfig
Host nerves.local
    UserKnownHostsFile /dev/null
    StrictHostKeyChecking no
```

## Authentication

It's possible to set up a number of authentication strategies with the Erlang
SSH daemon. Currently, only simple public key and username/password
authentication setups are supported by `:nerves_ssh`. Both of them work fine for
getting started. As needs become more sophisticated, you can pass options to
`:daemon_option_overrides`.

### Public key authentication

Public ssh keys can be specified so that matching clients can connect. These
come from files like your `~/.ssh/id_rsa.pub` or `~/.ssh/id_ecdsa.pub` that were
created when you created your `ssh` keys. If you haven't done this, the
following
[article](https://help.github.com/articles/generating-a-new-ssh-key-and-adding-it-to-the-ssh-agent/)
may be helpful. Here's an example that uses the application config:

```elixir
config :nerves_ssh,
  authorized_keys: [
    "ssh-rsa
AAAAB3NzaC1yc2EAAAADAQABAAAAgQDBCdMwNo0xOE86il0DB2Tq4RCv07XvnV7W1uQBlOOE0ZZVjxmTIOiu8XcSLy0mHj11qX5pQH3Th6Jmyqdj",
    "ssh-rsa
AAAAB3NzaC1yc2EAAAADAQABAAACAQCaf37TM8GfNKcoDjoewa6021zln4GvmOiXqW6SRpF61uNWZXurPte1u8frrJX1P/hGxCL7YN3cV6eZqRiF"
  ]
```

Here's another way that may work well for you that avoids needing to commit your
keys:

```elixir
config :nerves_ssh,
  authorized_keys: [
    File.read!(Path.join(System.user_home!, ".ssh/id_rsa.pub"))
  ]
```

See `NervesSSH.add_authorized_key/1` and `NervesSSH.remove_authorized_key/1`
for managing public keys at runtime.

### Username/password authentication

The SSH console uses public key authentication by default, but it can be
configured for usernames and passwords via the `:user_passwords` key. This has
the form `[{"username", "password"}, ...]`. Keep in mind that passwords are
stored in the clear. This is not recommended for most situations.

```elixir
config :nerves_ssh,
  user_passwords: [
    {"username", "password"}
  ]
```

You can use `NervesSSH.add_user/2` and `NervesSSH.remove_user/1` for managing
credentials at runtime, but they are not saved to disk so restarting `NervesSSH`
will cause them to be lost (such as a reboot or daemon crash)

## Upgrade from `NervesFirmwareSSH`

If you are migrating from `:nerves_firmware_ssh`, or updating to `:nerves_pack
>= 0.4.0`, you will need to make a few changes to your existing project.

1. Generate a `upload.sh` script by running `mix firmware.gen.script` (if you
   don't already have one)
   - This is necessary because you will no longer have access to your old
     `mix upload` command because `nerves_firmware_ssh` is being removed from
     the project.
2. Change all `:nerves_firmware_ssh` config values to `:nerves_ssh`. A command
   like this would probably do the trick:

    ```sh
    grep -RIl nerves_firmware_ssh config/ | xargs sed -i 's/nerves_firmware_ssh/nerves_ssh/g'
    ```

3. Compile your new firmware that includes `:nerves_ssh` (or updated
   `:nerves_pack`)
    * **NOTE** Compiling your new firmware for the first time will generate a
      warning about the old `upload.sh` script still being around. You can
      ignore that **this one time** because you will need it for uploading to an
      existing device still using port 8989.
4. Upload your new firmware with `:nerves_ssh` using the **_old_** `upload.sh`
   script (or whatever other method you have been using for OTA firmware
   updates)
5. After the new firmware with `:nerves_ssh` is on the device, then you'll need
   to generate the new `upload.sh` script with `mix firmware.gen.script`, or see
   [SSHSubsystemFwup](https://hexdocs.pm/ssh_subsystem_fwup/readme.html) for
   other supported options

## Goals

* [X] Support public key authentication
* [X] Support username/password authentication
* [X] Device generated server certificate and key
* [ ] Device generated username/password
