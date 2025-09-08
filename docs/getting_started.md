# Getting started with OVCS

## Local environment setup (Linux)

* Install asdf dependencies: See https://asdf-vm.com/guide/getting-started.html#_1-install-dependencies

* Install asdf: `git clone https://github.com/asdf-vm/asdf.git ~/.asdf` or `brew install asdf` if you prefer homebrew
* Install erlang:  `asdf plugin add erlang https://github.com/asdf-vm/asdf-erlang.git && asdf install erlang 27.3.4.2 && asdf set erlang 27.3.4.2 --home`
* Install elixir: `asdf plugin add elixir https://github.com/asdf-vm/asdf-elixir.git && asdf install elixir 1.17 && asdf set elixir 1.17 --home`
* Install Nodejs: `asdf plugin add nodejs https://github.com/asdf-vm/asdf-nodejs.git && asdf install nodejs 24.7.0 && asdf set nodejs 24.7.0 --home`
* Install ruby dependencies: `sudo apt install libffi-dev libyaml-dev`
* Install Ruby: `asdf plugin add ruby && asdf install ruby 3.3.5 && asdf set ruby 3.3.5 --home`
* Install Nerves: See https://hexdocs.pm/nerves/installation.html
* Install can-utils: `sudo apt install can-utils`
* Clone OVCS wherever you'd like

## Local environment VM setup (MacOs & Linux) - WIP

OVCS relies on the vcan module which allows you to create virtual can interfaces. This is a linux only kernel module, that can only be found in "non cloud image" kernels. Therefore, in order to use OVCS on your mac, you will need to use a full fledged VM. We recommend using Ubuntu through multipass for this.

* Follow the instructions to install multipass here: https://canonical.com/multipass/install
* Run `multipass launch --name primary --disk 40G --cpus 2 --memory 8G`, adjust the paremeters to your needs. Note that if you plan to compile the system images in it, you'll need a decent disk space, that cannot be changed later.
* Run `multipass shell` to get access to a shell in your VM.
* Set your system according to your needs
* Set the ubuntu user passwd with `sudo passwd ubuntu`
* (Mac only) In order to avoid issues with permissions and symlinks when creating nerves images, it is recommanded to clone ovcs in the VM itself and then setup an NFS share with the host so you can use your favorite editor in MacOs.
* Follow the regular installation process above

## Setting up your local directories with system images

OVCS is being developed on Raspberry PI Zero, 4 & 5 and the base system image for the VMS module and the Infotainment module are available in a seperate repositories.

We recommend the following directory structure:

```
└── ovcs_base
    ├── ovcs
    ├── ovcs_base_can_system_rpi4
    ├── ovcs_base_can_system_rpi5
    └── ovcs_base_can_system_rpi3a
```

In order to end up with this structure, run the following in a directoy of your choosing:

```
mkdir ovcs_base
cd ovcs_base
git clone https://github.com/open-vehicle-control-system/ovcs.git
git clone https://github.com/open-vehicle-control-system/ovcs_base_can_system_rpi4
git clone https://github.com/open-vehicle-control-system/ovcs_base_can_system_rpi5
git clone https://github.com/open-vehicle-control-system/ovcs_base_can_system_rpi3a
```

Next: [Applications](./applications.md)
