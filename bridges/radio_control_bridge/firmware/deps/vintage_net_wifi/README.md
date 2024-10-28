![vintage net logo](assets/logo.png)

[![Hex version](https://img.shields.io/hexpm/v/vintage_net_wifi.svg "Hex version")](https://hex.pm/packages/vintage_net_wifi)
[![API docs](https://img.shields.io/hexpm/v/vintage_net_wifi.svg?label=hexdocs "API docs")](https://hexdocs.pm/vintage_net_wifi/VintageNetWiFi.html)
[![CircleCI](https://circleci.com/gh/nerves-networking/vintage_net_wifi.svg?style=svg)](https://circleci.com/gh/nerves-networking/vintage_net_wifi)
[![Coverage Status](https://coveralls.io/repos/github/nerves-networking/vintage_net_wifi/badge.svg?branch=main)](https://coveralls.io/github/nerves-networking/vintage_net_wifi?branch=main)

`VintageNetWiFi` makes it easy to add WiFi support for your device. This can be
as simple as connecting to a WiFi access point or starting a WiFi access point
so that other computers can connect directly.

You will need a WiFi module to use this library. If you're using Nerves, the
official Raspberry Pi and Beaglebone systems contain WiFi drivers for built-in
modules. If you are using a USB WiFi module, make sure that the Linux device
driver for that module is loaded and any required firmware is available.

Once that's done, all that you need to do is add `:vintage_net_wifi` to your
`mix` dependencies like this:

```elixir
def deps do
  [
    {:vintage_net_wifi, "~> 0.12.0", targets: @all_targets}
  ]
end
```

> VintageNetWiFi also requires that the `wpa_supplicant` package and necessary
> WiFi kernel modules are included in the system. All officially supported
> Nerves systems that run on hardware with WiFI should work.
>
> In Buildroot, check that `BR2_PACKAGE_WPA_SUPPLICANT` is enabled. Even if you
> don't plan to use WPA3, enable `BR2_PACKAGE_WPA_SUPPLICANT_WPA3` as well so
> that the generic WiFi configurations don't fail due to parse errors.
>
> If you are using access point mode, check that `CONFIG_UDHCPD` is enabled
> in Busybox and `BR2_PACKAGE_WPA_SUPPLICANT_HOTSPOT` is enabled in Buildroot.

## Usage

The easiest way to configure WiFi is to using
`VintageNetWiFi.quick_configure/2`. For example:

```elixir
iex> VintageNetWiFi.quick_configure("my_access_point", "secret_passphrase")
:ok
```

Using `VintageNet.info` to check whether you're connected. If there's no
connection and you think there should be one, try watching the logs. On Nerves,
the normal ways are to run `RingLogger.next`, `RingLogger.viewer` or
`log_attach`/`log_detach` from an IEx prompt. (Hopefully the console or a wired
network interface works)

The second easiest way to create WiFi configurations is to use the helper
functions in `VintageNetWiFi.Cookbook`. Check out the module documentation for
the various configurations.

See the `VintageNetWiFi.quick_configure/2` documentation for details on WPA3
support.

## Advanced usage

WiFi network interfaces typically have names like `"wlan0"` or `"wlan1"` when
using Nerves. Most of the time, there's only one WiFi interface and its
`"wlan0"`. Some WiFi adapters expose separate interfaces for 2.4 GHz and 5 GHz
and they can be configured independently.

An example WiFi configuration looks like this:

```elixir
config :vintage_net,
  config: [
    {"wlan0",
      %{
        type: VintageNetWiFi,
        vintage_net_wifi: %{
          networks: [
            %{
              key_mgmt: :wpa_psk,
              ssid: "my_network_ssid",
              psk: "a_passphrase_or_psk",
            }
          ]
        },
        ipv4: %{method: :dhcp},
      }
    }
  ]
```

The `:ipv4` key is handled by `vintage_net` to set the IP address on the
connection. Most of the time, you'll want to use DHCP to dynamically get an IP
address.

The `:vintage_net_wifi` key has the following common fields:

* `:ap_scan` -  See `wpa_supplicant` documentation. The default for this, 1,
  should work for nearly all users.
* `:bgscan` - Periodic background scanning to support roaming within an ESS.
  * `:simple`
  * `{:simple, args}` - args is a string to be passed to the `simple` wpa module
  * `:learn`
  * `{:learn, args}` args is a string to be passed to the `learn` wpa module
* `:passive_scan`
  * 0:  Do normal scans (allow active scans) (default)
  * 1:  Do passive scans.
* `:regulatory_domain`: Two character country code. Technology configuration
  will take priority over Application configuration
* `:networks` - A list of Wi-Fi networks to configure. In client mode,
  VintageNet connects to the first available network in the list. In host mode,
  the list should have one entry with SSID and password information.
  * `:mode` -
    * `:infrastructure` (default) - Normal operation. Associate with an AP
    * `:ap` - access point mode
    * `:ibss` - peer to peer mode (not supported)
    * `:p2p_go` - P2P Go mode (not supported)
    * `:p2p_group_formation` - P2P Group Formation mode (not supported)
    * `:mesh` - mesh mode
  * `:ssid` - The SSID for the network
  * `:key_mgmt` - WiFi security mode (`:wpa_psk` for WPA2, `:none` for no
    password or WEP, `:sae` for pure WPA3, or `:wpa_psk_sha256` for WPA2 with
    SHA256). Not used if `:allowed_key_mgmt` is set.
  * `:allowed_key_mgmt` - A list of allowed WiFi security modes. See `:key_mgmt`
    for options. Supported in v0.12.1+. VintageNetWiFi's configuration
    normalizer automatically sets `:key_mgmt` to the first option in the list
    for backwards compatibility with v0.12.0 and earlier.
  * `:psk` - A WPA2 passphrase or the raw PSK. If a passphrase is passed in, it
    will be converted to a PSK and discarded.
  * `:sae_password` - A password for use with SAE authentication. This is
    similar to a passphrase that you could supply to `:psk`, but it has less
    length restrictions.
  * `:priority` - The priority to set for a network if you are using multiple
    network configurations
  * `:scan_ssid` - Scan with SSID-specific Probe Request frames (this can be
    used to find APs that do not accept broadcast SSID or use multiple SSIDs;
    this will add latency to scanning, so enable this only when needed)
  * `:frequency` - When in `:ibss` mode, use this channel frequency (in MHz).
    For example, specify 2412 for channel 1.
  * `:ieee80211w` - Whether management frame protection is enabled. Set to `0`,
    `1`, `2` or `:disabled`, `:optional`, `:required`.

These keys fairly directly map to the keys in the [official
docs](https://w1.fi/cgit/hostap/plain/wpa_supplicant/wpa_supplicant.conf).
`VintageNetWiFi` performs some checks on the keys to avoid typos and other easy
mistakes from breaking the `wpa_supplicant.conf` file. To inspect the generated
configuration, run `File.read("/tmp/vintage_net/wpa_supplicant.conf.wlan0")`.

If you do not want VintageNetWiFi to generate a `wpa_supplicant.conf` file for
you, you can specify the contents for yourself by using the
`:wpa_supplicant_conf` key. For example,

```elixir
iex> VintageNet.configure("wlan0", %{
      type: VintageNetWiFi,
      vintage_net_wifi: %{
        wpa_supplicant_conf: """
        network={
          ssid="home"
          key_mgmt=WPA-PSK
          psk="very secret passphrase"
        }
        """
      },
      ipv4: %{method: :dhcp}
    })
```

Please note that the syntax of the `:wpa_supplicant_conf` key is **NOT**
validated by VintageNet and we do not recommend them method unless you are
troubleshooting the `wpa_supplicant` or are working on a new feature.

WPA PSK example:

```elixir
iex> VintageNet.configure("wlan0", %{
      type: VintageNetWiFi,
      vintage_net_wifi: %{
        networks: [
          %{
            key_mgmt: :wpa_psk,
            psk: "a_passphrase_or_psk",
            ssid: "my_network_ssid"
          }
        ]
      },
      ipv4: %{method: :dhcp}
    })
```

WEP example:

```elixir
iex> VintageNet.configure("wlan0", %{
      type: VintageNetWiFi,
      vintage_net_wifi: %{
        networks: [
          %{
            ssid: "my_network_ssid",
            wep_key0: "42FEEDDEAFBABEDEAFBEEFAA55",
            key_mgmt: :none,
            wep_tx_keyidx: 0
          }
        ]
      },
      ipv4: %{method: :dhcp}
    })
```

WPA3-only example:

```elixir
iex> VintageNet.configure("wlan0", %{
      type: VintageNetWiFi,
      ipv4: %{method: :dhcp},
      vintage_net_wifi: %{
        networks: [
          %{
            key_mgmt: :sae,
            ssid: "my_network_ssid",
            sae_password: "a_password",
            ieee80211w: 2
          }
        ]
      }
    })
```

WPA2 w/ SHA256 example:

```elixir
iex> VintageNet.configure("wlan0", %{
      type: VintageNetWiFi,
      ipv4: %{method: :dhcp},
      vintage_net_wifi: %{
        networks: [
          %{
            key_mgmt: :wpa_psk_sha256,
            ssid: "my_network_ssid",
            psk: "a_password",
            ieee80211w: 2
          }
        ]
      }
    })
```

Enterprise Wi-Fi (WPA-EAP) support mostly passes through to the
`wpa_supplicant`. Instructions for enterprise network for Linux should map. For
example:

```elixir
iex> VintageNet.configure("wlan0", %{
      type: VintageNetWiFi,
      vintage_net_wifi: %{
        networks: [
          %{
            ssid: "testing",
            key_mgmt: :wpa_eap,
            pairwise: "CCMP TKIP",
            group: "CCMP TKIP",
            eap: "PEAP",
            identity: "user1",
            password: "supersecret",
            phase1: "peapver=auto",
            phase2: "MSCHAPV2"
          }
        ]
      },
      ipv4: %{method: :dhcp}
})
```

Network adapters that can run as an Access Point can be configured as follows:

```elixir
iex> VintageNet.configure("wlan0", %{
      type: VintageNetWiFi,
      vintage_net_wifi: %{
        networks: [
          %{
            mode: :ap,
            ssid: "test ssid",
            key_mgmt: :none
          }
        ]
      },
      ipv4: %{
        method: :static,
        address: "192.168.24.1",
        netmask: "255.255.255.0"
      },
      dhcpd: %{
        start: "192.168.24.2",
        end: "192.168.24.10",
        options: %{
          dns: ["1.1.1.1", "1.0.0.1"],
          subnet: "255.255.255.0",
          router: ["192.168.24.1"]
        }
      }
})
```

If your device may be installed in different countries, you should override the
default regulatory domain to the desired country at runtime.  VintageNet uses
the global domain by default and that will restrict the set of available WiFi
frequencies in some countries. For example:

```elixir
iex> VintageNet.configure("wlan0", %{
      type: VintageNetWiFi,
      vintage_net_wifi: %{
        regulatory_domain: "US",
        networks: [
          %{
            ssid: "testing",
            key_mgmt: :wpa_psk,
            psk: "super secret"
          }
        ]
      },
      ipv4: %{method: :dhcp}
})
```

Network adapters that can be configured to support 80211s mesh networking can be
configured as follows:

(Raspberry Pi internal WiFi modules do **not** support 80211s meshing)

```elixir
VintageNet.configure("mesh0", %{
  type: VintageNetWiFi,
  vintage_net_wifi: %{
    user_mpm: 1,
    networks: [
      %{
        ssid: "my-mesh",
        key_mgmt: :none,
        mode: :mesh
      }
    ]
  }
})
```

Mesh nodes connected to external networks can set so called "meshgate" params.
See [this document](https://github.com/o11s/open80211s/wiki/HOWTO#mesh-gate) for
more information

```elixir
VintageNet.configure("mesh0", %{
  type: VintageNetWiFi,
  vintage_net_wifi: %{
    user_mpm: 1,
    networks: [
      %{
        ssid: mesh_id,
        key_mgmt: :none,
        mode: :mesh,
        mesh_hwmp_rootmode: 4,
        mesh_gate_announcements: 1
      }
    ]
  }
})
```

Note that the example mesh configuration does not contain IP address settings.
All standard IP schemes are acceptable, but which one to use depends on the
network configuration. The simplest way to test the mesh network is to have
every node configure a static predictable IP address. DHCP will also work, but
this forces a "client/server" configuration meaning that nodes joining the
network will need to decide if they should be a DHCP server or client.

## Properties

In addition to the common `vintage_net` properties for all interface types, this
technology reports the following:

Property        | Values           | Description
 -------------- | ---------------- | -----------
`access_points` | [%AccessPoint{}] | A list of access points as found by the most recent scan
`clients`       | ["11:22:33:44:55:66"] | A list of clients connected to the access point when using `mode: :ap`
`current_ap`    | %AccessPoint{}   | The currently associated access point
`peers`         | [%MeshPeer{}]    | a list of mesh peers that the current node knows about when using `mode: :mesh`
`event`         | %Event{}         | WiFi control events not otherwise handled

Access points are identified by their BSSID. Information about an access point
has the following form:

```elixir
%VintageNetWiFi.AccessPoint{
  band: :wifi_5_ghz,
  bssid: "8a:8a:20:88:7a:50",
  channel: 149,
  flags: [:wpa2_psk_ccmp, :ess],
  frequency: 5745,
  signal_dbm: -76,
  signal_percent: 57,
  ssid: "MyNetwork"
}
```

Mesh peers are identified by their BSSID. Information about a peer has the following form:

```elixir
%VintageNetWiFi.MeshPeer{
  active_path_selection_metric_id: 1,
  active_path_selection_protocol_id: 1,
  age: 2339,
  authentication_protocol_id: 0,
  band: :wifi_2_4_ghz,
  beacon_int: 1000,
  bss_basic_rate_set: "10 20 55 110 60 120 240",
  bssid: "f8:a2:d6:b5:d4:07",
  capabilities: 0,
  channel: 5,
  congestion_control_mode_id: 0,
  est_throughput: 65000,
  flags: [:mesh],
  frequency: 2432,
  id: 7,
  mesh_capability: 9,
  mesh_formation_info: 2,
  mesh_id: "my-mesh",
  noise_dbm: -89,
  quality: 0,
  signal_dbm: -27,
  signal_percent: 97,
  snr: 62,
  ssid: "my-mesh",
  synchronization_method_id: 1
}
```

Applications can scan for access points in a couple ways. The first is to call
`VintageNet.scan("wlan0")`, wait for a second, and then call
`VintageNet.get(["interface", "wlan0", "wifi", "access_points"])`. This works
for scanning networks once or twice. A better way is to subscribe to the
`"access_points"` property and then call `VintageNet.scan("wlan0")` on a timer.
The `"access_points"` property updates as soon as the WiFi module notifies that
it is complete so applications don't need to guess how long to wait.

If you're using `RingLogger` (which is the default for Nerves) then you probably
also want to call `RingLogger.attach` to receive any logs in your terminal which
may include information about the wifi connection.

### Events

Some `wpa_supplicant` events like `CTRL-EVENT-ASSOC-REJECT` are passed on
through the "event" property to be handled outside `VintageNetWifi`. These
events might be useful, but optional.

## Signal quality info in STA (client) mode

You can send `ioctl` command to get information about signal level, quality and
other info when connected to network in STA mode. Run:

```elixir
VintageNet.ioctl("wlan0", :signal_poll)
```

Example output:

```elixir
{:ok, %VintageNetWiFi.SignalInfo{
  center_frequency1: 2462,
  center_frequency2: 0,
  frequency: 2472,
  linkspeed: 300,
  signal_dbm: -32,
  signal_percent: 94,
  width: "40 MHz"
}}
```

## Debugging

Unfortunately, when you're getting started for the very first time, WiFi can be
quite frustrating. Error messages and logs are not all that helpful. The first
debugging step is to connect to your device (over a UART or USB Gadget or maybe
a wired Ethernet connection). Run:

```elixir
iex> VintageNet.info
```

Double check that all of your parameters are set correctly. The `:psk` cannot be
checked here, so if you suspect that's wrong, double check your `config.exs`.
The next step is to look at log messages for connection errors. On Nerves
devices, run `RingLogger.next` at the `IEx` prompt.
