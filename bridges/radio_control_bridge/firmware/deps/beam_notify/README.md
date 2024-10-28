# BEAMNotify

[![Hex version](https://img.shields.io/hexpm/v/beam_notify.svg "Hex version")](https://hex.pm/packages/beam_notify)
[![API docs](https://img.shields.io/hexpm/v/beam_notify.svg?label=hexdocs "API docs")](https://hexdocs.pm/beam_notify/BEAMNotify.html)
[![CircleCI](https://circleci.com/gh/nerves-networking/beam_notify.svg?style=svg)](https://circleci.com/gh/nerves-networking/beam_notify)

Send a message to the BEAM from a shell script

This is one solution sending notifications from non-BEAM programs into Elixir.
`BEAMNotify` lets you set up a GenServer that listens for notifications from
shell scripts or anything that can invoke an OS process. Communication is via a
Unix Domain socket. Messages are limited to strings that passed via commandline
arguments or the environment to the `beam_notify` binary.

There are, of course, other ways of solving this problem. Some non-Elixir
programs already expose Unix domain or TCP socket interfaces for communication.
This might be a better choice. You could also use
[erl_call](http://erlang.org/doc/man/erl_call.html) or write a [C
node](http://erlang.org/doc/apps/erl_interface/ei_users_guide.html#introduction)
and communicate over distributed Erlang.

## Overview

`BEAMNotify` would typically be added to a supervision tree in your program.
Options to `BEAMNotify` specify things like its name, a dispatch function to
call, and other things.

The shell script (or any program) needs to call the `beam_notify` program
supplied by this library. The message is passed via commandline arguments or
environment variables (see `:report_env` option).

Since `beam_notify` needs to know how to connect to the appropriate
`BEAMNotify` GenServer (there may be more than one), the shell script must pass
some options. To make this easy, `BEAMNotify` provides two environment
variables by calling `BEAMNotify.env/1`:

1. `$BEAM_NOTIFY` - the absolute path to the `beam_notify` executable
2. `$BEAM_NOTIFY_OPTIONS` - how `beam_notify` should connect

In the shell script, run `$BEAM_NOTIFY` and pass it any arguments that you want
send up. `BEAMNotify` reports environment variables too.

If it is not possible to pass the `$BEAM_NOTIFY*` environment variables through
to your script due to a restricted shell environment, see the restricted shell
section below.

Back in Elixir, whenever a proper message is received, `BEAMNotify` will call
the dispatch function. The dispatch function is responsible for forwarding on
messages however makes sense in your application. If handling is simple, you can
process them in the dispatch function. You could also publish them through
`Phoenix.PubSub` or another pubsub service. `BEAMNotify` only handles strings,
so if you want to be fancier with your messages or filter them, you'll have to
add that to your dispatcher function.

It is important to keep in mind that the amount of data that can be sent in a
notification is limited by the transport and by OS limits on commandline
arguments. Suffice it to say that this is not intended for file transfer.

## Example

What we're going to do is create a script that sends a message to Elixir.
First, make sure that you have `:beam_notify` by either cloning this project or
creating a test Elixir project (`mix new ...`) and adding it to the `mix.exs`:

```elixir
def deps do
  [
    {:beam_notify, "~> 0.2.0"}
  ]
end
```

Now open an editor and create `simple.sh` with the following contents:

```sh
#!/bin/sh

echo "This is simple.sh"

$BEAM_NOTIFY Hello world
```

Start up Elixir with `iex -S mix`:

```elixir
# Get the PID that's running the IEx console
iex> us = self()
#PID<0.204.0>

# Start a BEAMNotify GenServer. The dispatcher function sends a tuple with the
# arguments and environment passed in from the shell script.
iex> BEAMNotify.start_link(name: "sulu", report_env: true, dispatcher: &send(us, {&1, &2}))
{:ok, #PID<0.211.0>}

# Run the shell script. We're doing this from Elixir, but you
# can also grab the environment by calling `BEAMNotify.env/1` and run it
# in another terminal window.
iex> System.cmd("/bin/sh", ["simple.sh"], env: BEAMNotify.env("sulu"))
{"This is simple.sh\n", 0}

# See what was sent
iex> flush
{["Hello", "world"], %{...}}
```

## Supervision example

Here's a code snippet of starting a hypothetical non-Elixir program that needs
to send messages back to Elixir. This code is part of a [module-based
supervisor](https://hexdocs.pm/elixir/Supervisor.html#module-module-based-supervisors),
but this isn't necessary. Two GenServers are started: one for `BEAMNotify` and
one to start and monitor the non-Elixir program using
[`MuonTrap.Daemon`](https://hexdocs.pm/muontrap/MuonTrap.Daemon.html).

Note how `BEAMNotify.env/1` is used to pass the proper environment to the
program.

```elixir
  @impl Supervisor
  def init(_) do
    beam_notify_options = [name: "my_beam", dispatcher: &Some.function/2]
    children = [
      {BEAMNotify, beam_notify_options},
      {MuonTrap.Daemon,
       [
         "/path/to/program",
         ["-s", "script_calling_beam_notify.sh"],
         [log_output: :debug, env: BEAMNotify.env(beam_notify_options)]
       ]}
    ]

    opts = [strategy: :one_for_one]
    Supervisor.start_link(children, opts)
  end
```

If you're lucky, it might be sufficient to call `BEAMNotify.bin_path/0` to get
the path to the `beam_notify` program and pass that directly to the non-Elixir
program. You'll still need to set the environment for `beam_notify` to work. On
the bright side, this will skip out having your system start `bash` on each
notification.

## Restricted shell environments

Some programs clear the OS environment before running programs as a security
precaution. It's still possible send messages to Elixir.

You'll need to know the path to the `beam_notify` binary and have a place to put
the communications socket that both Elixir and the `beam_notify` binary can
open. In this example, the socket will be created as
`/tmp/my_beam_notify_socket`. In Elixir, the `BEAMNotify` child_spec might look
like this:

```elixir
{BEAMNotify, name: "any name", path: "/tmp/my_beam_notify_socket", dispatcher: &Some.function/2}
```

For the script, here's a sample for Nerves devices where code is installed under
`/srv/erlang`.

```sh
#!/bin/sh

BEAM_NOTIFY=$(ls /srv/erlang/lib/beam_notify-*/priv/beam_notify)

$BEAM_NOTIFY -p /tmp/my_beam_notify_socket -- hello
```

The arguments following the `--` are passed. The `-p /tmp/my_beam_notify_socket`
part will be dropped.

Arguments are only parsed (and dropped) if `$BEAM_NOTIFY_OPTIONS` isn't defined.
In other words, `$BEAM_NOTIFY_OPTIONS` takes precedence.

## License

This library is covered by the Apache 2 license.
