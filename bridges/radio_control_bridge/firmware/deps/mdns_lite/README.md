# MdnsLite

[![Hex version](https://img.shields.io/hexpm/v/mdns_lite.svg "Hex version")](https://hex.pm/packages/mdns_lite)
[![CircleCI](https://circleci.com/gh/nerves-networking/mdns_lite.svg?style=svg)](https://circleci.com/gh/nerves-networking/mdns_lite)

MdnsLite is a simple, limited, no frills implementation of an
[mDNS](https://en.wikipedia.org/wiki/Multicast_DNS) (Multicast Domain Name
System) client and server. It operates like DNS, but uses multicast instead of
unicast so that any computer on a LAN can help resolve names. In particular, it
resolves hostnames that end in `.local` and provides a way to advertise and
discovery service.

MdnsLite is intended for environments like on Nerves devices that do not already
have an `mDNS` service. If you're running on desktop Linux or on MacOS, you
already have `mDNS` support and do not need MdnsLite.

Features of MdnsLite:

* Advertise `<hostname>.local` and aliases for ease of finding devices
* Static (application config) and dynamic service registration
* Support for multi-homed devices. For example, mDNS responses sent on a network
  interface have the expected IP addresses for that interface.
* DNS bridging so that Erlang's built-in DNS resolver can look up `.local` names
  via mDNS.
* Caching of results and advertisements seen on the network
* Integration with
  [VintageNet](https://github.com/nerves-networking/vintage_net) and Erlang's
  `:inet` application for network interface monitoring
* Easy inspection of mDNS record tables to help debug service discovery issues

MdnsLite is included in [NervesPack](https://hex.pm/packages/nerves_pack) so you
might already have it!

## Configuration

A typical configuration in the `config.exs` file looks like:

```elixir
config :mdns_lite,
  # Advertise `hostname.local` on the LAN
  hosts: [:hostname],
  # If instance_name is not defined it defaults to the first hostname
  instance_name: "Awesome Device",
  services: [
    # Advertise an HTTP server running on port 80
    %{
      id: :web_service,
      protocol: "http",
      transport: "tcp",
      port: 80,
    },
    # Advertise an SSH daemon on port 22
    %{
      id: :ssh_daemon,
      protocol: "ssh",
      transport: "tcp",
      port: 22,
    }
  ]
```

The `services` section lists the services that the host offers, such as
providing an HTTP server. Specifying a `protocol`, `transport` and `port` is
usually the easiest way. The `protocol` and `transport` get combined to form the
service type that's actually advertised on the network. For example, a "tcp"
transport and "ssh" protocol will end up as `"_ssh._tcp"` in the advertisement.
If you need something custom, specify `:type` directly. Optional fields include
`:id`, `:weight`, `:priority`, `:instance_name` and `:txt_payload`. An `:id` is
needed to remove the service advertisement at runtime. If not specified,
`:instance_name` is inherited from the top-level config.  A `:txt_payload` is a
list of `"<key>=<value>"` string that will be advertised in a TXT DNS record
corresponding to the service.

See [`MdnsLite.Options`](https://hexdocs.pm/mdns_lite/MdnsLite.Options.html) for
information about all application environment options.

It's possible to change the advertised hostnames, instance names and services at
runtime. For example, to change the list of advertised hostnames, run:

```elixir
iex> MdnsLite.set_hosts([:hostname, "nerves"])
:ok
```

To change the advertised instance name:

```elixir
iex> MdnsLite.set_instance_name("My Other Awesome Device")
:ok
```

Here's how to add and remove a service at runtime:

```elixir
iex> MdnsLite.add_mdns_service(%{
    id: :my_web_server,
    protocol: "http",
    transport: "tcp",
    port: 80,
  })
:ok
iex> MdnsLite.remove_mdns_service(:my_web_server)
:ok
```

## Client

`MdnsLite.gethostbyname/1` uses mDNS to resolve hostnames. Here's an example:

```elixir
iex> MdnsLite.gethostbyname("my-laptop.local")
{:ok, {172, 31, 112, 98}}
```

If you just want mDNS to "just work" with Erlang, you'll need to enable
MdnsLite's DNS Bridge feature and configure Erlang's DNS resolver to use it. See
the DNS Bridge section for details.

Service discovery docs TBD...

## DNS Bridge configuration

`MdnsLite` can start a DNS server to respond to `.local` queries. This enables
code that has no knowledge of mDNS to resolve mDNS queries. For example,
Erlang/OTP's built-in DNS resolver doesn't know about mDNS. It's used to resolve
hosts for Erlang distribution and pretty much any code using `:gen_tcp` and
`:gen_udp`. `MdnsLite`'s DNS bridge feature makes `.local` hostname lookups work
for all of this. No code modifications required.

Note that this feature is useful on Nerves devices. Erlang/OTP can use the
system name resolver on desktop Linux and MacOS. The system name resolver should
already be hooked up to an mDNS resolver there.

To set this up, you'll need to enable the DNS bridge on `MdnsLite` and then set
up the DNS resolver to use it first. Here are the options for the application
environment:

```elixir
config :mdns_lite,
  dns_bridge_enabled: true,
  dns_bridge_ip: {127, 0, 0, 53},
  dns_bridge_port: 53

config :vintage_net,
  additional_name_servers: [{127, 0, 0, 53}]
```

The choice of running the DNS bridge on 127.0.0.53:53 is mostly arbitrary. This
is the default.

> #### Info {: .info}
>
> If you're using a version of Erlang/OTP before 24.1, you'll be affected by
> [OTP #5092](https://github.com/erlang/otp/issues/5092). The workaround is to
> add the `dns_bridge_recursive: true` option to the `:mdns_lite` config.

## Debugging

`MdnsLite` maintains a table of records that it advertises and a cache per
network interface. The table of records that it advertises is based solely off
its configuration. Review it by running:

```elixir
iex> MdnsLite.Info.dump_records
<interface_ipv4>.in-addr.arpa: type PTR, class IN, ttl 120, nerves-2e6d.local
<interface_ipv6>.ip6.arpa: type PTR, class IN, ttl 120, nerves-2e6d.local
_epmd._tcp.local: type PTR, class IN, ttl 120, nerves-2e6d._epmd._tcp.local
_services._dns-sd._udp.local: type PTR, class IN, ttl 120, _epmd._tcp.local
_services._dns-sd._udp.local: type PTR, class IN, ttl 120, _sftp-ssh._tcp.local
_services._dns-sd._udp.local: type PTR, class IN, ttl 120, _ssh._tcp.local
_sftp-ssh._tcp.local: type PTR, class IN, ttl 120, nerves-2e6d._sftp-ssh._tcp.local
_ssh._tcp.local: type PTR, class IN, ttl 120, nerves-2e6d._ssh._tcp.local
nerves-2e6d._epmd._tcp.local: type SRV, class IN, ttl 120, priority 0, weight 0, port 4369, nerves-2e6d.local.
nerves-2e6d._epmd._tcp.local: type TXT, class IN, ttl 120,
nerves-2e6d._sftp-ssh._tcp.local: type SRV, class IN, ttl 120, priority 0, weight 0, port 22, nerves-2e6d.local.
nerves-2e6d._sftp-ssh._tcp.local: type TXT, class IN, ttl 120,
nerves-2e6d._ssh._tcp.local: type SRV, class IN, ttl 120, priority 0, weight 0, port 22, nerves-2e6d.local.
nerves-2e6d._ssh._tcp.local: type TXT, class IN, ttl 120,
nerves-2e6d.local: type A, class IN, ttl 120, addr <interface_ipv4>
nerves-2e6d.local: type AAAA, class IN, ttl 120, addr <interface_ipv6>
```

Note that some addresses have not been filled in. They depend on which network
interface receives the query. The idea is that if a computer is looking for you
on the Ethernet interface, you should give records with that Ethernet's
interface rather than, say, the IP address of the WiFi interface.

`MdnsLite`'s cache is filled with records that it sees advertised. It's
basically the same, but can be quite large depending on the mDNS activity on a
link. It looks like this:

```elixir
iex> MdnsLite.Info.dump_caches
Responder: 172.31.112.97
  ...
Responder: 192.168.1.58
  ...
```

## In memory

[Peter Marks](https://github.com/pcmarks/) wrote and maintained the original
version of `mdns_lite`.

## License

Copyright (C) 2019-21 SmartRent

    Licensed under the Apache License, Version 2.0 (the "License");
    you may not use this file except in compliance with the License.
    You may obtain a copy of the License at [http://www.apache.org/licenses/LICENSE-2.0](http://www.apache.org/licenses/LICENSE-2.0)

    Unless required by applicable law or agreed to in writing, software
    distributed under the License is distributed on an "AS IS" BASIS,
    WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
    See the License for the specific language governing permissions and
    limitations under the License.
