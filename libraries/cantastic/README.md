# Cantastic

Cantastic is an Elixir library to interact with CAN/Bus via lib_socket_can (Linux only).
It does all the heavy lifting of parsing the incoming frames and sending the outgoing ones at the right frequencies.

## Installation

in the `mix.exs` file:

```elixir
def deps do
  [{:cantastic, "~> 0.1.0"}]
end
```

## Configuration

Cantastic is supports the following configuration options:

