# scripts/

Ad-hoc utility scripts that don't fit elsewhere. The canonical entry
point for everyday work is the [`ovcs` CLI](../cli/README.md); these are
fallbacks and developer-side tooling.

| Script | Purpose |
|--------|---------|
| [`setup_can.sh`](./setup_can.sh) | Brings up physical CAN interfaces (`can0`, `can1`, `can2` at 500 kbps) on a Nerves device when SSH'd in. Cantastic already does this at boot via `setup_can_interfaces: true`; use this script only for ad-hoc manual setup. For host-side **virtual** CAN, prefer `./ovcs can setup <vehicle>`. |
| [`bind_remote_can.rb`](./bind_remote_can.rb) | Tunnels CAN frames between a remote Nerves device and the local host using `socketcand` + `socketcand_client`. Example: `./bind_remote_can.rb ovcs1-vms.local can0,vcan0 can1,vcan1`. Useful for running the Vue dashboard on a laptop against CAN traffic on the vehicle. |
| [`faker.rb`](./faker.rb) | Generates synthetic CAN traffic for stress-testing the dashboard / decoders. Edit the script to pick frame IDs and networks. |
| [`sleep_loop.rb`](./sleep_loop.rb) | Toggles a specific CAN frame on/off on a loop — quick demo / debugging aid. |

For replaying real-vehicle CAN captures, see
[`docs/testing_can_messages.md`](../docs/testing_can_messages.md#replaying-can-dumps)
(uses `canplayer` against files under `candumps/`).
