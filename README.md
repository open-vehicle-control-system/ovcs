# OVCS

## What is OVCS?

OVCS stands for Open Vehicule Control system. It is a set of open-hardware and open-software components meant as a development platform for tinkering with vehicules.

OVCS is based on simple, off-the-shelve components to make it affordable and accessible to people with no to limited knowledge about the embedded computing world.

OVCS can help you:
* Retrofit a car or any other vehicule by providing an easy to modify system to interact with the vehicule's CAN buses
* Create a dashboard for any kind of vehicule using high-level web technologies such as the  Phoenix framework and Vue.js
* Make multiple components from different vehicule brands work together by aggregating the different CAN buses and providing a standardized set of CAN messages on the OVCS CAN bus.

## Disclaimer

OVCS is provided as is an without any warranty. Use it at your own risk. It is not road certified and therefore does not meet all required criteria to do so. We decline any responsibility for any incident resulting in the usage of OVCS. OVCS is a hobby research project.

## Deploy

* Run `./ovcs-cli build [vms|infotainment]` to build the firmwares, then either:
    * `./ovcs-cli burn [vms|infotainment]` to burn the firmwares on a SD card
    * `./ovcs-cli upload [vms|infotainment] [optional: host|ip address]` to upload the firmwares on the target

## Doc

You will find the documentation [here](https://github.com/open-vehicle-control-system/ovcs/blob/main/docs/README.md)

