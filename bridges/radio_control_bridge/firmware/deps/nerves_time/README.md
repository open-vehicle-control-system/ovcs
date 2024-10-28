# nerves_time

[![CircleCI](https://circleci.com/gh/nerves-time/nerves_time.svg?style=svg)](https://circleci.com/gh/nerves-time/nerves_time)
[![Hex version](https://img.shields.io/hexpm/v/nerves_time.svg "Hex version")](https://hex.pm/packages/nerves_time)

`NervesTime` keeps the system clock on [Nerves](http://nerves-project.org)
devices in sync when connected to the network and close to in sync when
disconnected. It's especially useful for devices lacking a [Battery-backed
real-time clock](https://en.wikipedia.org/wiki/Real-time_clock) and will advance
the clock at startup to a reasonable guess.

## Installation

First add `nerves_time` to your project's dependencies:

```elixir
def deps do
  [
    {:nerves_time, "~> 0.4.2"}
  ]
end
```

Ensure that your `vm.args` allows for
[timewarps](http://erlang.org/doc/apps/erts/time_correction.html#time-warp-modes).
If it doesn't, `nerves_time` will update the OS system time, but Erlang's system
time will lag. The following line should be in the beginning or middle of the
`vm.args` file:

```elixir
+C multi_time_warp
```

If you're using one of the official Nerves Systems, then this is all that's
needed. `nerves_time` requires Busybox's `ntpd` and `date` applets to be
enabled. If you haven't explicitly disabled them, they're probably enabled.

## Configuration

### Startup

`nerves_time` by default does not block waiting for a valid system time to be set.
This can result in your application running before the time has been adjusted, which
may be undesirable. To lessen the likelyhood of that happening you can adjust
the `:await_initialization_timeout` config to wait for a valid system time to be set.
If `nerves_time` fails to do that within the given timeframe it will stop blocking
startup and continue trying asynchronously.

```elixir
# config/config.exs

config :nerves_time, await_initialization_timeout: :timer.seconds(5)
```

### NTP

`nerves_time` uses [ntp.pool.org](https://www.ntppool.org/en/) for time
synchronization. Please see their [terms of
use](https://www.ntppool.org/tos.html) before tweaking `nerves_time`.
Alternative NTP servers can be specified using the `config.exs`:

```elixir
# config/config.exs

config :nerves_time, :servers, [
    "0.pool.ntp.org",
    "1.pool.ntp.org",
    "2.pool.ntp.org",
    "3.pool.ntp.org"
  ]
```

It's also possible to configure NTP servers at runtime. See
`NervesTime.set_ntp_servers/1`.

### Valid time range

`nerves_time` has a concept of a valid time range. This minimizes time
errors on systems without clocks or Internet connections or that may have some
issue that causes a very wrong time value. The default valid time range is
hardcoded and moves forward each release. It is not the build timestamp since
that results in [non-reproducible builds](https://reproducible-builds.org).
Applications can override the valid range via the application config:

```elixir
# config/config.exs

config :nerves_time, earliest_time: ~N[2019-10-04 00:00:00], latest_time: ~N[2022-01-01 00:00:00]
```

## Algorithm

Here's the basic idea behind `nerves_time`:

* If the clock hasn't been set or is invalid, set it to the earliest valid
  time known to `nerves_time`. This is either set in the application config or
  defaulted to a reasonable value that likely moves forward a little each
  `nerves_time` release.
* check for time via a [Real Time Clock](#Real-Time-Clock)
* Run Busybox `ntpd` to synchronize time using the [NTP
  protocol](https://en.wikipedia.org/wiki/Network_Time_Protocol).
* Update [Real Time Clock](#Real-Time-Clock) periodically and on graceful power
  downs. This is currently only done at around 11 minute intervals.

To check the NTP synchronization status, call `NervesTime.synchronized?/0`.

## Real Time Clock

A hardware based real time clock can be configured by added a config.exs entry:

```elixir
config :nerves_time, rtc: {SomeImplementingModule, [some: :initialization_opt]}
```

By default Nerves Time is configured to use `NervesTime.FileTime` which will
Check for `~/.nerves_time`. If it exists, advance the clock to it's last
modification time.

See the documentation for `NervesTime.RealTimeClock` to implement your own
real time clock.

## Credits and license

This project started as a fork of
[nerves_ntp](https://hex.pm/packages/nerves_ntp) by Marcin Operacz and Wojciech
Mandrysz. It has quite a few changes from since when they worked on the project,
but some of their code still exists. Both their project and this one are covered
by the [Apache-2.0 license](https://opensource.org/licenses/Apache-2.0).
