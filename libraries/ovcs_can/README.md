# OvcsCan

Shared CAN frame and signal definitions used by every OVCS Elixir app that
speaks CAN (`vms/core`, `infotainment/core`).

This library contains no runtime logic — only YAML data under
`priv/can/components/`: per-component frame specs (Bosch, Nissan, Orion,
OVCS-internal, Volkswagen, etc.) grouped by manufacturer.

Vehicle topology YAMLs live inside each vehicle package at
`vehicles/<name>/priv/can/{vms,infotainment}.yml`, with per-vehicle
controller wirings alongside them under
`vehicles/<name>/priv/can/generic_controller/`. Each side has its own
topology because VMS needs the full CAN topology while infotainment only
subscribes to the frames it actually renders.

Entry-point YAMLs reference this library via Cantastic's cross-app import
syntax:

```yaml
emitted_frames:
  - import!:@ovcs_can:can/components/ovcs/0x1A0_vms_status.yml
```

`@<otp_app>:<path>` resolves to `:code.priv_dir(otp_app) <> "/" <> path`.
