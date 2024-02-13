# Getting started with OVCS

## Local environment setup

* Install asdf dependencies: See https://asdf-vm.com/guide/getting-started.html#_1-install-dependencies
* Install asdf: `git clone https://github.com/asdf-vm/asdf.git ~/.asdf`
* Install erlang:  `asdf plugin add erlang https://github.com/asdf-vm/asdf-erlang.git && asdf install erlang 26.1.2 && asdf global erlang 26.1.2`
* Install elixir: `asdf plugin-add elixir https://github.com/asdf-vm/asdf-elixir.git && asdf install elixir 1.15.7 && asdf global elixir 1.15.7`
* Install NVM: `curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.5/install.sh | bash`
* Install Node: `nvm install node`
* Install NPM: `npm install -g npm`
* Install nervers: See https://hexdocs.pm/nerves/installation.html
* Install can-utils: `sudo apt-get install can-utils`

## Setting up your local directories with system images

OVCS is being developed on Raspberry PI 4 and the base system image for the ECU module and the Infotainment module are available in a seperate repositories:
* OVCS Infotainment system image: https://github.com/Spin42/ovcs_infotainment_system_rpi4
* OVCS ECU system image: https://github.com/Spin42/ovcs_ecu_system_rpi4

These system images must be cloned in the parent folder of this repository.

We recommend the following directory structure:

```
└── ovcs_base
    ├── ovcs
    ├── ovcs_infotainment_system_rpi4
    └── ovcs_ecu_system_rpi4
```

In order to end up with this structure, run the following in a directoy of your choosing:

```
mkdir ovcs_base
cd ovcs_base
git clone https://github.com/Spin42/ovcs.git
git clone https://github.com/Spin42/ovcs_infotainment_system_rpi4.git
git clone https://github.com/Spin42/ovcs_ecu_system_rpi4.git
```

Next: [Applications](./applications.md)