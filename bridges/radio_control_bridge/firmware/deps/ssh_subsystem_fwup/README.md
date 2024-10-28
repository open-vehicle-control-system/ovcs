# SSHSubsystemFwup

[![CircleCI](https://circleci.com/gh/nerves-project/ssh_subsystem_fwup/tree/main.svg?style=svg)](https://circleci.com/gh/nerves-project/ssh_subsystem_fwup/tree/main)
[![Hex version](https://img.shields.io/hexpm/v/ssh_subsystem_fwup.svg "Hex version")](https://hex.pm/packages/ssh_subsystem_fwup)

This library provides an [ssh](https://en.wikipedia.org/wiki/Secure_Shell)
subsystem that applies Nerves "over-the-air" firmware updates. It is an
alternative to
[`nerves_firmware_ssh`](https://github.com/nerves-project/nerves_firmware_ssh)
that extracts the update service to a `:ssh.daemon/1` spec. This trims down the
responsibilities of the library and makes it possible to:

1. Customize ssh authentication (for example, password-based auth is possible)
2. Handle host keys differently and more securely
3. Run firmware updates on port 22 with other ssh services

In addition, the protocol for sending updates over ssh has been simplified. If
you're coming from `nerves_firmware_ssh`, you'll have used the `upload.sh`
script or `mix upload`. This library provides the same interface. If using
`upload.sh`, you will need to rerun `mix firmware.gen.script` since the script
has changed.

## Installation

The easiest installation is to use
[`nerves_ssh`](https://github.com/nerves-project/nerves_ssh) and have it bring
in this library as a dependency. See that project for details.

However, if you do not want to use `nerves_ssh`, here's what do do. First, add
the dependency:

```elixir
def deps do
  [{:ssh_subsystem_fwup, "~> 0.6.0"}]
end
```

Then add ssh subsystem spec to the call that starts the `ssh` daemon. This code
will look something like:

```elixir
    {:ok, ref} =
      :ssh.daemon([
        {:subsystems, [SSHSubsystemFwup.subsystem_spec()]}
      ])
```

You will likely have many more options passed to the `ssh.daemon`.

## Uploading firmware

There are two ways of uploading firmware. The first is to run:

```shell
mix upload
```

That doesn't work for everyone due to `ssh` authentication preferences. The
alternative is to use commandline `ssh`. For convenience, `ssh_subsystem_fwup`
can generate a script that makes this easier. Go to your Nerves project
directory and run:

```shell
mix firmware.gen.script
```

This should create an `upload.sh` script. Frequently when starting out, you can
run `./upload.sh` without arguments since it will guess that it's supposed to
upload to `nerves.local`. To specify a device to upload to, pass the device's
hostname as the first argument. For example:

```shell
$ ./upload.sh nerves-1234.local
fwup: Upgrading partition B
|====================================| 100% (32.34 / 32.34) MB
Success!
Elapsed time: 4.720 s
Disconnected from 172.31.207.89 port 22
```

Note that the `.local` address assumes that mDNS has been configured on the
device and that mDNS works on your network and OS. That's not always the case
and a frequent source of frustration when it fails. When in doubt, check that
you can upload to the device's IP address. You can get the IP address from your
router or by connecting to the device's IEx prompt and running `ifconfig`.

## Upload protocol

It's not necessary to use the `upload.sh` script. The following line is
equivalent:

```shell
cat $firmware | ssh -s $nerves_device fwup
```

## Configuration

The default options should satisfy most use cases, but it's possible to alter
how updates are applied by passing options when creating the SSH subsystem spec
(see `SSHSubsystemFwup.subsystem_spec/1`) or by setting the application
environment.

Here's an example of what the code looks like when setting options via a
subsystem spec:

```elixir
      :ssh.daemon(@port, [
        ...
        {:subsystems, [SSHSubsystemFwup.subsystem_spec(task: "my_upgrade_task")]}
      ])
```

If another library starts the SSH deamon for you, like
[`nerves_ssh`](https://hex.pm/packages/nerves_ssh), it might be more convenient
to set options via the application environment. `ssh_subsystem_fwup` uses its
defaults first, then those from the application environment and finally those in
the subsystem spec, so as long as the options you specify in the application
environment aren't overridden, you'll be fine. Here's an example:

```elixir
config :ssh_subsystem_fwup, precheck_callback: {MyProject, :precheck, []}
```

The following options are available:

* `:devpath` - path for fwup to upgrade (Required)
* `:fwup_path` - path to the fwup firmware update utility
* `:fwup_env` - a list of name,value tuples to be passed to the OS environment for fwup
* `:fwup_extra_options` - additional options to pass to fwup like for setting
  public keys
* `:precheck_callback` - an MFArgs to call when there's a connection. If
  specified, the callback will be passed the username and the current set of
  options. If allowed, it should return `{:ok, new_options}`. Any other return
  value closes the connection.
* `:success_callback` - an MFArgs to call when a firmware update completes
  successfully. Defaults to `{Nerves.Runtime, :reboot, []}`.
* `:task` - the task to run in the firmware update. Defaults to `"upgrade"`

## License

Copyright (C) 2017-21 The Nerves Project Authors <developers@nerves-project.org>

    Licensed under the Apache License, Version 2.0 (the "License");
    you may not use this file except in compliance with the License.
    You may obtain a copy of the License at [http://www.apache.org/licenses/LICENSE-2.0](http://www.apache.org/licenses/LICENSE-2.0)

    Unless required by applicable law or agreed to in writing, software
    distributed under the License is distributed on an "AS IS" BASIS,
    WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
    See the License for the specific language governing permissions and
    limitations under the License.
