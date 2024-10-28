# nerves_motd

[![Hex version](https://img.shields.io/hexpm/v/nerves_motd.svg "Hex version")](https://hex.pm/packages/nerves_motd)
[![CircleCI](https://circleci.com/gh/nerves-project/nerves_motd.svg?style=svg)](https://circleci.com/gh/nerves-project/nerves_motd)

`nerves_motd` prints a ["message of the
day"](https://en.wikipedia.org/wiki/Motd_(Unix)) on Nerves devices.

![](https://user-images.githubusercontent.com/7563926/202566900-942f3963-ff0e-48c2-9e13-03f96dd9a0d0.png)

## Usage

The primary function is `NervesMOTD.print()` which prints the base layout based
on the template below:

```
<LOGO>
<APP_NAME> <APP_VERSION> (<FW_UUID>) <PLATFORM> <TARGET>
  Serial       : <SERIAL_NUMBER>
  Uptime       : 18.296 seconds
  Clock        : 2023-05-18 00:05:20 JST <synchronization state>

  Firmware     : <VALIDITY> (<A|B>)      Applications : <N> started (<not started applications>)
  Memory usage : 74 MB (15%)             Part usage   : 210 MB (14%)
  Hostname     : <HOSTNAME>              Load average : 0.05 0.14 0.15

  <IFNAME>     : <IPV6>, <IPV4>
  <EXTRA_ROWS>
```

To have `NervesMOTD` print automatically when first accessing a device, add
`NervesMOTD.print()` to your `iex.exs` file (typically in
`rootfs_overlay/etc/iex.exs`)

### Customization

`NervesMOTD.print/1` supports a few options for customizing the base layout:

* `:logo` - Change the logo displayed. Defaults to the Nerves logo. Set to `""`
  to prevent any logo from being displayed
* `:extra_rows` - a list of custom rows or a callback for returning rows to be
  appended to the end of the layout. The callback can be a 0-arity function
  reference or MFArgs tuple.

For convenience, `NervesMOTD.print/1` options may be stored in the application
environment in your `config.exs` to be used whenever `NervesMOTD.print/0` is
called:

```elixir
config :nerves_motd,
  logo: """
  Custom logo
  """,
  extra_rows: [
    [{"Label", "value"}, {"Label2", "value2"}],
    [{"Long label", "Lots of text"}]
  ]
```

## Installation

Install by adding `:nerves_motd` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:nerves_motd, "~> 0.1.0"}
  ]
end
```

For details, see [API reference](https://hexdocs.pm/nerves_motd/api-reference.html).

## License

Copyright (C) 2022 Masatoshi Nishiguchi, Nerves Project Authors

    Licensed under the Apache License, Version 2.0 (the "License");
    you may not use this file except in compliance with the License.
    You may obtain a copy of the License at [http://www.apache.org/licenses/LICENSE-2.0](http://www.apache.org/licenses/LICENSE-2.0)

    Unless required by applicable law or agreed to in writing, software
    distributed under the License is distributed on an "AS IS" BASIS,
    WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
    See the License for the specific language governing permissions and
    limitations under the License.
