# Generic Controller

A generic Arduino controller that lets the VMS actuate relays, read digital and analog inputs, and drive PWM / DAC over the CAN network — without having to program each board with a use-case-specific firmware. Targets the Arduino R4 Minima.

The guide, [Generic controllers](../../docs/generic_controllers/README.md), explains what
it drives, how frame ids and adoption work, the pin mapping, and how to flash, adopt and
verify a board; this README keeps the firmware's developer details.

## Flashing

Build / upload via PlatformIO:

```sh
pio run -e uno_r4_minima_prod -t upload
```

### Linux: USB permissions for the R4

Without a udev rule, `dfu-util` fails with `LIBUSB_ERROR_ACCESS` (`Cannot open DFU device 2341:0069`). Add the rule once per host:

```sh
sudo tee /etc/udev/rules.d/60-arduino-uno-r4.rules >/dev/null <<'EOF'
# Arduino UNO R4 Minima / WiFi — run mode
SUBSYSTEMS=="usb", ATTRS{idVendor}=="2341", ATTRS{idProduct}=="0069", MODE="0666"
SUBSYSTEMS=="usb", ATTRS{idVendor}=="2341", ATTRS{idProduct}=="1002", MODE="0666"
# DFU bootloader mode
SUBSYSTEMS=="usb", ATTRS{idVendor}=="2341", ATTRS{idProduct}=="0369", MODE="0666"
SUBSYSTEMS=="usb", ATTRS{idVendor}=="2341", ATTRS{idProduct}=="1102", MODE="0666"
EOF

sudo udevadm control --reload-rules
sudo udevadm trigger
```

Unplug + replug the board afterwards. Double-tap the reset button if the upload doesn't drop the board into DFU automatically.

## Tests

```sh
pio test -e local_test
```

The `local_test` environment runs the Unity tests under `test/` on the host.
