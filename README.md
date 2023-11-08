# OVCS infotainment 

## Applications

* `ovcs_infotainment_backend`: Phoenix app connecting to the CAN/Bus and exposing the internal API
* `ovcs_infotainment_firmware`: Nerves app packaging the backend on a Raspberry
* `ovcs_infotainment_frontend`: Vue.js App displaying the car interface. Served as static files by the backend app in prod

## Local Development

* Run `mix phx.server` in the  `ovcs_infotainment_backend` folder to run the Phoenix app.
* Run `npm run dev` in the `ovcs_infotainment_frontend` folder to run the Vue.js app.

## Deploy

* Run `./build.sh` to build the firmware then, either:
    * run `./burn.sh` to burn a sd card
    * run `./upload_over_usb.sh` to update an existing Raspberry connected to your host over USB 