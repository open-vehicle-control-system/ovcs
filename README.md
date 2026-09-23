# Open Vehicle Control System (OVCS)

An open-source framework for vehicle embedded systems, built with [Elixir](https://elixir-lang.org/), [Nerves](https://nerves-project.org/), [Phoenix](https://www.phoenixframework.org/) and [Flutter](https://flutter.dev/). It makes components from different manufacturers work together: each manufacturer's CAN bus stays isolated, and a Vehicle Management System (VMS) on a Raspberry Pi translates and orchestrates them.

OVCS contains no vehicle-specific code. A vehicle is an **application** of the framework: a package under `vehicles/` that the firmware loads at boot. Three reference applications show it on real hardware:

| Reference application | What it is |
|---|---|
| [OVCS1](./vehicles/ovcs1/README.md) | 2007 VW Polo converted to electric: Nissan Leaf AZE0 drivetrain, Bosch iBooster Gen2, Orion BMS2, the Polo's original systems. Drivable, manual and remote. |
| [OVCS Mini](./vehicles/ovcs_mini/README.md) | Traxxas 4WD RC car with a VESC-driven motor, for radio-control and ROS 2 work. |
| [OBD2](./vehicles/obd2/README.md) | The VMS as an OBD2 / UDS scan tool for any car. |

Your own vehicle is another application, and needs none of them. See [Framework and applications](./docs/framework.md).

## Quick start

On Linux, after [Getting started](./docs/getting_started.md):

```sh
./ovcs run ovcs_mini       # every firmware of the application, on virtual CAN
./ovcs attach ovcs_mini    # in another terminal: logs, bus, CAN and IEx panes
```

The debug dashboard is on `http://localhost:5173`. [Quickstart](./docs/quickstart.md) goes further; [Simulation](./compose/local/simulation/README.md) needs only Docker.

## Documentation

The guides live in [`docs/`](./docs/README.md) and are published on [ovcs.be/docs](https://ovcs.be/docs). Start with [Architecture](./docs/architecture.md) and [Your application package](./docs/vehicle_parameterisation.md).

## Presentations and media

| Event | Date | Links |
|---|---|---|
| ElixirConf EU 2024 | April 2024 | [Video: Retrofitting a Car and Running it with Elixir](https://www.youtube.com/watch?v=2rL5yIEUU84) · [Slides](https://github.com/open-vehicle-control-system/presentations/tree/main/ElixirconfEU%20%2019-04-2024) |
| Makilab | November 2024 | [Slides](https://github.com/open-vehicle-control-system/presentations/tree/main/Makilab%204-11-2024) |
| FOSDEM 2025 | February 2025 | [Video: Converting an '07 car to an RC EV using open source software](https://www.youtube.com/watch?v=b74WbEGoPgI) · [Video: Building a robot from a Traxxas RC car](https://www.youtube.com/watch?v=KSj2oYt7g1E) · [Slides](https://github.com/open-vehicle-control-system/presentations/tree/main/Fosdem%202-2-2025) |
| OVCS teaser | 2025 | [Video: Open Vehicle Control System teaser](https://www.youtube.com/watch?v=429IfI6uzBg) |

More on the [Spin42 Engineering YouTube channel](https://www.youtube.com/@spin42engineering) and in [Community and talks](./docs/community.md).

## Disclaimer

OVCS is a hobby research project, provided as-is without warranty. It is not road-certified and does not meet the criteria to be. Use it at your own risk; the authors decline any responsibility for incidents resulting from its use.

## License

[MIT License](./LICENCE.txt), copyright (c) 2026 Spin42 SRL.
