# Cantastic

Cantastic is an Elixir library to interact with CAN/Bus via lib_socket_can (Linux only).
It does all the heavy lifting of parsing the incoming frames and sending the outgoing ones at the right frequencies.

/!\ Disclaimer: this library is still at a very early development stage. Breaking change can be introduced at any time.

## Installation

in the `mix.exs` file:

```elixir
def deps do
  [{:cantastic, "~> 0.1.0"}]
end
```

## OTP App Configuration

### Example

```elixir
config :cantastic,
  can_networks: "ovcs:can0,leaf_drive:can1,polo_drive:can2",
  setup_can_interfaces: true,
  otp_app: :vms_core,
  priv_can_config_path: "polo_2007.yml",
  enable_socketcand: true,
  socketcand_ip_interface: "wlan0"
```

## Description

Cantastic is supports the following configuration options:

| Key | Description | Default value |
|-----|-------------|---------------|
| `:can_networks` | A comma separated list of can network names and related interfaces. | N/A
| `:setup_can_interfaces`| Wheher Cantastic should setup the CAN interfaces. It requires the Elixir user to have the approriate rights (usually the case for Nerves hosts). | `false` |
| `:otp_app` | The name of the OTP app owning the priv directory where the can config file is stored | N/A
| `:priv_can_config_path` | The relative path where the Yaml config file is located | N/A
| `:enable_socketcand` | Wheter Cantastic should start the socketcand server on all configured interfaces. This allows to remotely access the CAN interfaces for debugging.| `false` |
| `:socketcand_ip_interface` | The IP interface on which socketcand should listen to. | `"eth0"` |

## CAN configuration file

Cantastic requires you to define a YAML describing the frames to be sent and received and how to structure them.
This allows you to declaratively define your CAN networks in a clear and maintainable format.

### Example

```yaml
---
can_networks:
  ovcs:
    bitrate: 500000
    emitted_frames:
      - name: contactors_status_request
        id: 0x100
        frequency: 20
        signals:
          - name: main_negative_contactor_enabled
            kind: enum
            value_start: 0
            value_length: 8
            mapping:
              0x00: false
              0x01: true
          - name: main_positive_contactor_enabled
            kind: enum
            value_start: 8
            value_length: 8
            mapping:
              0x00: false
              0x01: true
    received_frames:
      - name: car_controls_status
        id: 0x200
        frequency: 10
        signals:
          - name: raw_max_throttle
            kind: integer
            value_start: 0
            value_length: 16
          - name: raw_throttle
            kind: integer
            value_start: 16
            value_length: 16
          - name: requested_gear
            kind: enum
            value_start: 48
            value_length: 8
            mapping:
              0x00: drive
              0x01: neutral
              0x02: reverse
              0x03: parking
```

## Description

TODO