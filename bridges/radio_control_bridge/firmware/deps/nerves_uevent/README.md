# NervesUEvent

[![CircleCI](https://circleci.com/gh/nerves-project/nerves_uevent/tree/main.svg?style=svg)](https://circleci.com/gh/nerves-project/nerves_uevent/tree/main)
[![Hex version](https://img.shields.io/hexpm/v/nerves_uevent.svg "Hex version")](https://hex.pm/packages/nerves_uevent)

NervesUEvent listens for events from the Linux kernel, automatically loads
device drivers, and forwards them to your Elixir programs.

NervesUEvent is a very simple version of the Linux `udevd`. Just like `udevd`
does for desktop Linux, NervesUEvent registers to receive UEvents from the Linux
kernel. Unlike `udevd`, NervesUEvent only runs `modprobe` when needed and keeps
track of what hardware is in the system. For most Nerves use cases, `udevd`
isn't needed.

> #### Warning {: .warning}
>
> Almost all Nerves systems require some kernel modules to be automatically
> loaded or critical functionality won't work. WiFi device drivers, for example,
> are almost always kernel modules. If you're not using NervesUEvent or `udevd`
> or some other library that automatically loads kernel modules, you'll need to
> add calls to `modprobe` to your application.

Nerves projects generally depend on either `:nerves_uevent` or a version of
[`:nerves_runtime`](https://hex.pm/packages/nerves_runtime) that included
similar functionality. It's an advanced use case to modify this dependency.

## Configuration

NervesUEvent automatically starts on boot. Configuration is supplied via
application config. The following option is available:

* `:autoload_modules` - defaults to `true` to automatically run `modprobe` when
  needed

Here's a `config.exs` example:

```elixir
config :nerves_uevent, autoload_modules: false
```

## Usage

NervesUEvent is currently very low level in what it reports and reflects the
Linux representation. For example, say that you're interested in an MMC device
and you've found out that Linux exposes it in the
`/sys/devices/platform/soc/2100000.bus/2194000.mmc` directory. Linux also sends
UEvent messages for all devices in `/sys/device`, so NervesUEvent will know
about this too. To query NervesUEvent for device information, drop `/sys` off
the path and convert to a list of strings like this:

```elixir
iex> NervesUEvent.get(["devices", "platform", "soc", "2100000.bus", "2190000.mmc"])
%{
  "driver" => "sdhci-esdhc-imx",
  "modalias" => "of:NmmcT(null)Cfsl,imx6ull-usdhcCfsl,imx6sx-usdhc",
  "of_alias_0" => "mmc1",
  "of_compatible_0" => "fsl,imx6ull-usdhc",
  "of_compatible_1" => "fsl,imx6sx-usdhc",
  "of_compatible_n" => "2",
  "of_fullname" => "/soc/bus@2100000/mmc@2190000",
  "of_name" => "mmc",
  "subsystem" => "platform"
}
```

Some devices have more useful information than others. This particular one
mostly shows information found in the device tree file for this device. Of note
is the `"modalias"` key. When NervesUEvent sees this, it will try to load the
appropriate Linux kernel driver for this device if one exists.

More usefully, you can subscribe for events. For example, if you'd like to be
notified when a MicroSD card has been inserted, you can subscribe to all events
on that device:

```elixir
iex> NervesUEvent.subscribe(["devices", "platform", "soc", "2100000.bus", "2190000.mmc"])
```

If you're not sure what to subscribe to, subscribe to all events to see what happens:

```elixir
iex> NervesUEvent.subscribe([])
```

Now if you physically insert a MicroSD card, NervesUEvent will send messages to
your process mailbox. Here's one of the events:

```elixir
iex> flush
%PropertyTable.Event{
  table: NervesUEvent,
  timestamp: 2558213871126,
  property: ["devices", "platform", "soc", "2100000.bus", "2190000.mmc", "mmc_host", "mmc0", "mmc0:1234"],
  value: %{
    "mmc_name" => "SA04G",
    "mmc_type" => "SD",
    "modalias" => "mmc:block",
    "subsystem" => "mmc"
  },
  previous_timestamp: nil,
  previous_value: nil
}
```

The primary fields of interest are `:table`, `:timestamp`, `:property`, and
`:value`. NervesUEvent uses the PropertyTable library for storing everything and
publishing changes. The timestamps are from `System.monotonic_time/0`.

## License

Copyright (C) 2017-22 Nerves Project Authors

    Licensed under the Apache License, Version 2.0 (the "License");
    you may not use this file except in compliance with the License.
    You may obtain a copy of the License at [http://www.apache.org/licenses/LICENSE-2.0](http://www.apache.org/licenses/LICENSE-2.0)

    Unless required by applicable law or agreed to in writing, software
    distributed under the License is distributed on an "AS IS" BASIS,
    WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
    See the License for the specific language governing permissions and
    limitations under the License.
