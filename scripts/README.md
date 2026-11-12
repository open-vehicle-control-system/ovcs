# scripts/

Ad-hoc utility scripts that don't fit elsewhere. The canonical entry
point for everyday work is the [`ovcs` CLI](../cli/README.md); these are
fallbacks and developer-side tooling.

| Script | Purpose |
|--------|---------|
| [`setup_can.sh`](./setup_can.sh) | Brings up physical CAN interfaces (`can0`, `can1`, `can2` at 500 kbps) on a Nerves device when SSH'd in. Cantastic already does this at boot via `setup_can_interfaces: true`; use this script only for ad-hoc manual setup. For host-side **virtual** CAN, prefer `./ovcs can setup <vehicle>`. |
| [`bind_remote_can.rb`](./bind_remote_can.rb) | Tunnels CAN frames between a remote Nerves device and the local host using `socketcand` + `socketcand_client`. Example: `./bind_remote_can.rb ovcs1-vms.local can0,vcan0 can1,vcan1`. Useful for running the VMS dashboard on a laptop against CAN traffic on the vehicle. |
| [`faker.rb`](./faker.rb) | Generates synthetic CAN traffic for stress-testing the dashboard / decoders. Edit the script to pick frame IDs and networks. |
| [`check_docs.exs`](./check_docs.exs) | Checks the guides linked from `docs/README.md` against the [documentation rules](../CODE_STYLING.md#guides) (frontmatter, no H1, no Mermaid or raw HTML, fence languages, vocabulary, relative links and anchors, repository paths in inline code). Runs in CI. |
| [`libraries.sh`](./libraries.sh) | Clones the sideloaded libraries into `libraries/` at the commits pinned in [`libraries.tsv`](./libraries.tsv) (`mise run libraries`), or fails when a clone is not at its pin (`mise run libraries-check`, run in CI). |
| [`expand_urdf.sh`](./expand_urdf.sh) | Expands each `vehicles/<name>/description/*.urdf.xacro` into the `.urdf` committed beside it, which the vehicle package reads at compile time and the compute node publishes (`mise run urdf`, needs ROS's `xacro`). CI fails while one is stale. |
| [`camera_pose.py`](./camera_pose.py) | Measures a vision unit camera's pose relative to the stereo pair from chessboard image pairs, with OpenCV and NumPy. The pose goes in the `:camera` component's `:pose` ([Measure the pose](../docs/vision/cameras.md#measure-the-pose)). Its tests: `python3 -I -m unittest discover -s scripts/tests`. |
| [`sleep_loop.rb`](./sleep_loop.rb) | Toggles a specific CAN frame on/off on a loop — quick demo / debugging aid. |

For replaying real-vehicle CAN captures, see
[`docs/testing_with_can.md`](../docs/testing_with_can.md#replaying-can-dumps)
(uses `canplayer` against files under `candumps/`).
