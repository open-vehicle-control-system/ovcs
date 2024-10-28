# CRC

[![Module Version](https://img.shields.io/hexpm/v/crc.svg)](https://hex.pm/packages/crc)
[![Hex Docs](https://img.shields.io/badge/hex-docs-lightgreen.svg)](https://hexdocs.pm/crc/)
[![Total Download](https://img.shields.io/hexpm/dt/crc.svg)](https://hex.pm/packages/crc)
[![License](https://img.shields.io/hexpm/l/crc.svg)](https://github.com/TattdCodeMonkey/crc/blob/master/LICENSE)
[![Last Updated](https://img.shields.io/github/last-commit/TattdCodeMonkey/crc.svg)](https://github.com/TattdCodeMonkey/crc/commits/master)

This module is used to calculate CRC (Cyclic Redundancy Check) values for binary data. It uses NIF functions written in C to iterate over the given binary calculating the CRC checksum value. The NIFs are written to report their time slice usage and will not interfere with the schedulers.

## Installation

### Elixir

Add `:crc` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:crc, "~> 0.10"}
  ]
end
```

### Erlang

Add `crc` to your `rebar.config`:

```erlang
{deps, [
  {crc, "0.10.5"}
]}.
```

Or `erlang.mk`:

```erlang
dep_crc = hex 0.10.5
```

## Supported algorithms (models)

Run `CRC.list/0` to get a full list of all pre-defined models or `CRC.list/1` with a filter to search for a pre-defined model.

## Usage

To calculate a CRC-16 X-Modem checksum for the binary `<<1,2,3,4,5,4,3,2,1>>` using the pre-defined model:

```elixir
iex> CRC.crc(:crc_16_xmodem, <<1,2,3,4,5,4,3,2,1>>)
31763

iex> CRC.calculate(<<1,2,3,4,5,4,3,2,1>>, :crc_16_xmodem)
31763
```

Or you can create a model at runtime, this can be done with a map:

```elixir
iex> CRC.crc(
  %{
    width: 16,
    poly: 0x1021,
    init: 0x00,
    refin: false,
    refout: false,
    xorout: 0x00
  },
  <<1,2,3,4,5,4,3,2,1>>
)
31763
iex> CRC.calculate(
  <<1,2,3,4,5,4,3,2,1>>,
  %{
    width: 16,
    poly: 0x1021,
    init: 0x00,
    refin: false,
    refout: false,
    xorout: 0x00
  }
)
31763
```

Or you can extend one of the pre-defined models:

```elixir
iex> CRC.crc(
  %{
    extend: :crc_16_xmodem,
    init: 0x00,
  },
  <<1,2,3,4,5,4,3,2,1>>
)
31763
```

`CRC.crc_init/1` is used to create a resource and be used to do partial updates to a calculation that is then finalized later:

```elixir
iex> resource = CRC.crc_init(:crc_16_xmodem)
#Reference<x.x.x.x>

iex> resource2 = CRC.crc_update(resource, <<1, 2, 3, 4, 5>>)
#Reference<y.y.y.y>

iex> resource3 = CRC.crc_update(resource2, <<4, 3, 2, 1>>)
#Reference<z.z.z.z>

iex> CRC.crc_final(resource3)
31763
```

This could be useful to calculate a CRC for a larger binary that you are receiving asynchronously.

## Tests

CRC implementations have been tested against these online calculators to validate their correctness to the best of our ability.

-  https://www.lammertbies.nl/comm/info/crc-calculation.html
-  http://www.sunshine2k.de/coding/javascript/crc/crc_js.html

There are also two property tests that can use [PyCRC](https://github.com/tpircher/pycrc) or [CRC RevEng](https://sourceforge.net/projects/reveng/) if installed and configured locally.

```bash
$ export PYCRC_BIN=~/pycrc-0.9.1/pycrc.py
$ export REVENG_BIN=~/reveng-1.5.2/reveng
$ mix test
```

PyCRC is used as a part of the TravisCI test suite.

## Copyright and License

Copyright (c) 2015 Rodney Norris

CRC is released under the MIT License. See the [LICENSE.md](./LICENSE.md) file
for further details.
