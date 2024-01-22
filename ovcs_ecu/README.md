# OVCS ECU

## Run

```
$  mix run --no-halt 
```

## Requirements

### I/O

* CAN/Bus
* drive/neutral/reverse
* Ignition input
* Brake input? 
* Throttle pedal (6 lines on Resolve VCU)
* Power delivery module (PDM) ? (5 lines on Resolve VCU)
* Inverter ? (2 lines on Resolve VCU)
* Battery managment system (BMS)? (7 lines on Resolve VCU)
* Reverse light relay?
* Brake light relay? (when regen is larger than 40Nm on Resolve VCU)
* Radiator fan relay?
* Should activate inverter and waterpump when the car turns on


### Notes:

- The Leaf battery pack has a precharge circuit with high voltage relays and a resistor. If the heating element isn’t connected properly the precharge resistor could break. To prevent this from happening it should only be possible to turn on the heating element after the second precharge relay has turned on. The Resolve controller pin[12] sends out 12V when that relay should turn on.

- When the brake pedal is pushed down the throttle pedal is turned off. This makes it safer when braking since torque can’t be applied, however this makes burnouts a lot harder.

- To shift gears RPM must be near zero, the throttle pedal must be fully released and the brake pedal must be pushed down (assuming the Resolve controller is connected to the brake input). Then simply push the desired gear button.

- There are three modes of regen off, 1 and 2. To change regen strength press the drive button while in the Drive mode. Regen is turned off when the SOC is above 80%.

- There is an option to max charge the car to 80% for increased longevity of the battery pack. To turn it off or on simply push down the Neutral button during charging. After that “80% max” should be displayed like the picture to the left. 

- Relevant certifications: EMC tested & ECE - R10 Certified!

