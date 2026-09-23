---
title: Community and talks
description: Conference videos, slides, the forum thread, the GitHub organisation, and how to contribute.
---

## Where it comes from

OVCS was started in early 2024 by [Marc Lainez](https://github.com/mlainez), [Loïc Vigneron](https://github.com/loicvigneron) and [Thibault Poncelet](https://github.com/thibaultponcelet) at [Spin42](https://www.spin42.com/), to make vehicle embedded computing accessible with off-the-shelf components and high-level languages. The team built the framework and, on it, the reference applications that prove it works:

- **OVCS1**: a 2007 Volkswagen Polo converted to electric with a Nissan Leaf AZE0 drivetrain, a Bosch iBooster Gen2, an Orion BMS2 and custom Arduino controllers, orchestrated by Elixir on Raspberry Pis running Nerves.
- **OVCS Mini**: a Traxxas RC car, so remote-control and ROS 2 work can be developed safely before it reaches the full-size car.
- **OBD2**: a scan tool for any car with a diagnostic port.

The talks mostly show OVCS1 and OVCS Mini; what they demonstrate is the framework underneath. See [Framework and applications](./framework.md).

## Talks and videos

| Event | Date | Watch and read |
|---|---|---|
| ElixirConf EU 2024 | April 2024 | [Retrofitting a Car and Running it with Elixir](https://www.youtube.com/watch?v=2rL5yIEUU84) (video) · [slides](https://github.com/open-vehicle-control-system/presentations/tree/main/ElixirconfEU%20%2019-04-2024) |
| Makilab | November 2024 | [slides](https://github.com/open-vehicle-control-system/presentations/tree/main/Makilab%204-11-2024) |
| FOSDEM 2025 | February 2025 | [Converting an '07 car to an RC EV using open source software](https://www.youtube.com/watch?v=b74WbEGoPgI) (video) · [Building a robot from a Traxxas RC car](https://www.youtube.com/watch?v=KSj2oYt7g1E) (video) · [slides](https://github.com/open-vehicle-control-system/presentations/tree/main/Fosdem%202-2-2025) |
| OVCS teaser | 2025 | [Open Vehicle Control System teaser](https://www.youtube.com/watch?v=429IfI6uzBg) (video) |

Build logs and demos: the [Spin42 Engineering YouTube channel](https://www.youtube.com/@spin42engineering).

## Ask and discuss

- [Elixir Forum thread](https://elixirforum.com/t/driving-a-car-powered-with-nerves-and-elixir/71557): the announcement and the discussion around it.
- [GitHub issues](https://github.com/open-vehicle-control-system/ovcs/issues): bugs, questions and proposals.

## Repositories

Everything lives under the [open-vehicle-control-system](https://github.com/open-vehicle-control-system) GitHub organisation.

| Repository | What it is |
|---|---|
| [ovcs](https://github.com/open-vehicle-control-system/ovcs) | The monorepo: the framework, the three reference applications under `vehicles/`, and these docs |
| [cantastic](https://github.com/open-vehicle-control-system/cantastic) | YAML-driven CAN library: SocketCAN, frame encoding and decoding, ISO-TP, OBD2 |
| [express_lrs](https://github.com/open-vehicle-control-system/express_lrs) | MAVLink v2 receive-only decoder for ExpressLRS handsets |
| [msp_osd](https://github.com/open-vehicle-control-system/msp_osd) | MSP / DisplayPort OSD stack for HDZero, Walksnail and DJI video transmitters |
| [ovcs_control](https://github.com/open-vehicle-control-system/ovcs_control) | PID controller, input filters, and an interactive tuning simulator |
| [presentations](https://github.com/open-vehicle-control-system/presentations) | Slide decks from the talks |
| [ovcs_base_can_system_rpi4](https://github.com/open-vehicle-control-system/ovcs_base_can_system_rpi4) | Nerves system: Raspberry Pi 4 with CAN, for the VMS and the ROS bridge |
| [ovcs_base_can_system_rpi5](https://github.com/open-vehicle-control-system/ovcs_base_can_system_rpi5) | Nerves system: Raspberry Pi 5 with CAN and display, for the infotainment |
| [ovcs_base_can_system_rpi3a](https://github.com/open-vehicle-control-system/ovcs_base_can_system_rpi3a) | Nerves system: Raspberry Pi 3A, for the radio control bridge |
| [ovcs_bridges_system_rpi5](https://github.com/open-vehicle-control-system/ovcs_bridges_system_rpi5) | Nerves system: Raspberry Pi 5 for the perception bridge (stereo cameras, Hailo-8) |

`mise run libraries` sideloads the four libraries into `libraries/`, because they are useful outside OVCS. The framework-internal contracts (`ovcs_bridge`, `ovcs_bus`, `ovcs_can`, `ovcs_vehicle`, `ovcs_drivers`) live in the monorepo. See [Framework components](./applications.md).

## Contributing

Set up as any user would ([Getting started](./getting_started.md)), then check:

```sh
git clone https://github.com/open-vehicle-control-system/ovcs.git
cd ovcs
mise install
mise run cli
./ovcs doctor
```

Before opening a pull request:

- **Style.** [`CODE_STYLING.md`](../CODE_STYLING.md) documents the conventions. Credo covers the Elixir apps, Ruff the Python tooling, `cspell` the spelling. Guides follow the documentation rules in [`CLAUDE.md`](../CLAUDE.md) and pass `elixir scripts/check_docs.exs`.
- **CI runs on pull requests.** `.github/workflows/` holds `ci.yml` (the Elixir tree), `firmware.yml` (every firmware build, the only thing that catches a host-versus-target OTP mismatch) and `ros2.yml` (the container stacks, including the check that the Zenoh pins agree).
- **Sideloaded libraries have their own repositories.** A change to Cantastic, ExpressLRS, MSP OSD or ovcs_control is a pull request there, not against `libraries/` here.
- **Applications live in `vehicles/`.** A new vehicle is a new application scaffolded with `./ovcs new`, not a framework change. The cores, firmware shells and libraries stay free of vehicle-specific code; if your application needs something the framework cannot express, open a separate framework pull request. See [Your application package](./vehicle_parameterisation.md).
- **The reference applications are examples, not requirements.** Fixes to them are welcome; nothing in a new application should depend on them.
- **Nerves systems are forks** pinned to upstream tags; [Toolchain and OTP](./toolchain_and_otp.md) has the migration recipe.

## Disclaimer and licence

> [!CAUTION]
> OVCS is a hobby research project, provided as-is without warranty. It is not road-certified and does not meet the criteria to be. Use it at your own risk; the authors decline any responsibility for incidents resulting from its use.

OVCS is released under the [MIT License](../LICENCE.txt), copyright Spin42 SRL. No neural-network weights are committed: the YOLOv8 weights the perception pipeline can use are AGPL-licensed and don't compose with MIT. `mise run fetch-models` downloads them and prints each licence first. The default Hailo model is the Apache-2.0 NanoDet-RepVGG.
