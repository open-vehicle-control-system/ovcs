# UBootEnv

[![CircleCI](https://circleci.com/gh/nerves-project/uboot_env.svg?style=svg)](https://circleci.com/gh/nerves-project/uboot_env)
[![Hex version](https://img.shields.io/hexpm/v/uboot_env.svg "Hex version")](https://hex.pm/packages/uboot_env)

This library lets you read and write [U-Boot](https://www.denx.de/wiki/U-Boot)
environment blocks from Elixir. U-Boot environment blocks are simple key-value
stores used by the U-Boot bootloader and applications that need to communicate
with it. Nerves uses U-Boot environment blocks to store settings related to the
device and running firmware. Nerves uses the format even for boards (like the
Raspberry Pis) that don't use the U-Boot bootloader.

This library has the following features:

* Create, read, and write to U-Boot environment blocks in pure Elixir with OTP
  21 and later
* Load environment block configurations from `/etc/fw_env.config`
* Redundant and non-redundant environment block support

This library does not support U-Boot environment blocks stored in raw NAND Flash
or big-endian blocks.

## Installation

Install by adding `uboot_env` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:uboot_env, "~> 1.0"}
  ]
end
```

## Using

Here's an example of reading the environment:

```elixir
iex> UBootEnv.read()
{:ok,
 %{
   "fdt_addr" => "0x83000000",
   "stdout" => "serial",
   ...
 }
}
```

To change the environment, update the map returned by `UBootEnv.read/0` and call
`UBootEnv.write/1`. If you're used to using `fw_setenv`, note that
`UBootEnv.write/1` writes the map that you give it whereas `fw_setenv` merges
the key value pairs with the current environment.

```elixir
iex> {:ok kv} = UBootEnv.read()
iex> new_kv = Map.put(kv, "hello", "world")
iex> UBootEnv.write(new_kv)
:ok
```

`UBootEnv.read/0` and `UBootEnv.write/1` do not perform any locking of the data
they write. If you have multiple processes updating the U-Boot environment
block, you'll have to synchronize access to it.

## License

This code is Apache 2 licensed.
