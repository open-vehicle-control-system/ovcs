# PropertyTable

[![CircleCI](https://circleci.com/gh/nerves-project/property_table.svg?style=svg)](https://circleci.com/gh/nerves-project/property_table)
[![Hex version](https://img.shields.io/hexpm/v/property_table.svg "Hex version")](https://hex.pm/packages/property_table)
[![Coverage Status](https://coveralls.io/repos/github/nerves-project/property_table/badge.svg)](https://coveralls.io/github/nerves-project/property_table)

<!-- MODULEDOC -->
In-memory key-value store with subscriptions

PropertyTable makes it easy to set up a key-value store where users can subscribe to changes based on patterns. PropertyTable refers to keys as
properties. Properties have values and are timestamped as to when they
received that value. Subscriptions make this library feel similar to Publish-Subscribe. Events, though, are only for changes to properties.

PropertyTable is useful when you want to expose a decent amount of state and
let consumers pick and choose what parts interest them.

PropertyTable consumers express their interest in properties using "patterns". A pattern could be as simple as the property of interest or it could contain
wildcards. This allows one to create hierarchical key-value stores, map-based
stores, or just simple key-value stores with notifications.

PropertyTable is optionally persistent to disk. Keys and values are backed by ETS.
<!-- MODULEDOC -->

## Example

While configurable, the default property style for PropertyTable is a `String` list. This enables a hierarchical key-value store. One use case that is
roughly hierarchical is exposing network interface status to users. Imagine
a `NetworkTable` set up like the following:

```sh
NetworkTable
├── available_interfaces
│   └── [eth0, eth1]
└── interface
|   ├── eth0
|   │   ├── config
|   |   |   └── %{ipv4: %{method: :dhcp}}
|   │   └── connection
|   |       └── :internet
|   └── eth1
|       ├── config
|       |   └── %{ipv4: %{method: :static}}
|       └── connection
|           └── :disconnected
└── connection
    └── :internet
```

In this example, `NetworkTable` would be the name of the PropertyTable. The
connection status of "eth1" would be represented as `["interface", "eth1",
"connection"]` and have a value of `:disconnected`.

The library maintaining this table (the producer) creates the PropertyTable by
adding a `child_spec` to its supervision tree:

```elixir
{PropertyTable, name: NetworkTable}
```

To run this example from the IEx prompt, start the PropertyTable manually by
calling `PropertyTable.start_link/1`:

```elixir
PropertyTable.start_link(name: NetworkTable)
```

Inserting properties into the table looks like:

```elixir
PropertyTable.put(NetworkTable, ["available_interfaces"], ["eth0", "eth1"])
PropertyTable.put(NetworkTable, ["connection"], :internet)
PropertyTable.put(NetworkTable, ["interface", "eth0", "config"], %{ipv4: %{method: :dhcp}})
PropertyTable.put(NetworkTable, ["interface", "eth0", "connection"], :internet)
```

Read one property by running:

```elixir
PropertyTable.get(NetworkTable, ["interface", "eth0", "config"])
```

Since the format for properties is naturally hierarchical, you can get multiple
by matching on a pattern that contains the start of the property that you want:

```elixir
PropertyTable.match(NetworkTable, ["interface"])
```

You can subscribe to changes to receive a message after each change
happens. For example, to receive a message when any property starting with
`"interface"` changes, run:

```elixir
PropertyTable.subscribe(table, ["interface"])
```

Test with:

```elixir
PropertyTable.put(NetworkTable, ["interface", "eth0", "connection"], :disconnected)
flush
```

Then when a property changes value, the Erlang process that called
`PropertyTable.subscribe/2` will receive a `%PropertyTable.Event{}` message:

```elixir
%PropertyTable.Event{
  table: NetworkTable,
  property: ["interface", "eth0", "connection"],
  value: :disconnected
  timestamp: 200,
  previous_value: :internet,
  previous_timestamp: 100
}
```

The timestamps in the event are from `System.monotonic_time/0`. In this example,
you could calculate the time that "eth0" was connected to the internet by
subtracting the timestamps.

## String path properties and patterns

The default property format is a list of strings. Patterns are also list of
strings and are "prefix" matched. For example, the pattern `["a"]` would match
the properties `["a"]` and `["a", "b"]` but not `["c"]`. String path patterns
also support two positional wildcards:

* `:"$"` - do not match paths that have additional elements
* `:_` - match any string in that location

For example, if you want to match `["a", "b"]` exactly, use the pattern `["a",
"b", :"$"]`. Likewise, if you don't care what's an a position in the string,
specify `:_` like `[:_, "b"]`.

## Custom property types and patterns

It's possible to replace the string path pattern matching in PropertyTable by
providing an implementation for the `PropertyTable.Matcher` behaviour. The
important function is `matches?`:

```elixir
@callback matches?(PropertyTable.pattern(), PropertyTable.property()) :: boolean()
```

PropertyTable calls this function when deciding whether to send a property
change event to a subscriber and when you call `PropertyTable.match/2`.

Pass your module that implements the `PropertyTable.Matcher` behaviour as an
option to PropertyTable:

```elixir
{PropertyTable, name: NetworkTable, matcher: MyCustomMatcher}
```

## Efficiency

PropertyTable has a sweet spot in what it supports. It's not intended for very
large datasets nor is it the most efficient solution for all patterns. As a
rough guide, the use cases we had in mind with PropertyTable have in the low
1000s of keys, a couple producers, a dozen consumers, and changes are bursty.
Optimization choices were made with that in mind. This means:

* Reads query ETS directly, but changes to properties are routed through one
  GenServer. This reduces processing in the producer's thread context at the
  cost of creating a potential bottleneck on multicore machines
* Publishing events iterates over all subscriber patterns. This adds a lot of
  flexibility to patterns. Given the design target of a dozen or so consumers,
  it seemed that any indexing or optimization to reduce the number of
  subscribers looked at would be slower overall than just trying each pattern.
* Getting a specific property is very fast (one ETS looking on an indexed key),
  but matching is slow. Matching iterates over every property. This allows for a
  lot of flexibility in patterns. The expectation that matching is not a common
  task, and that users will subscribe to changes over repeatedly calling match.

## License

Copyright (C) 2022 Nerves Project Authors

    Licensed under the Apache License, Version 2.0 (the "License");
    you may not use this file except in compliance with the License.
    You may obtain a copy of the License at [http://www.apache.org/licenses/LICENSE-2.0](http://www.apache.org/licenses/LICENSE-2.0)

    Unless required by applicable law or agreed to in writing, software
    distributed under the License is distributed on an "AS IS" BASIS,
    WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
    See the License for the specific language governing permissions and
    limitations under the License.
