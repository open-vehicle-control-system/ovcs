# Orion BMS

## Wiring

* Ready and charging inputs into Orion
* Safety relays (charge enable signal, charge saftey signal and discharge enable signal), see page 27 of the wiring manual.
* J1772 control pilot and proximity detect
* Always on power source: to allow J1772 charging, BMS will go in low consumption mode as soon as ready and charge inputs are disabled. (see p 34)
* Ready power source: to be enabled by VMS at ignition
* Charge power source: to be enabled while charging (charge and ready can be enabled at the same time -> enabling interlock mode), charge signal can be provided by a small AC/DC power adapter powered off the mains.
* All wiring must be properly fused, see p 21

NB: All outputs are open drain outputs.
NB: Charge enable can be sent through can, Charge safety must be used as an ANALOG backup.

## CAN Frames

### Frame to be sent to Orion:

- (J1772 charging) AC main voltage, from Leaf charger -> 0x390 Bit27-29
- keep alive frame from VMS

### Frame to be sent to Leaf charger:

- (J1772 charging) DC charging current limit to leaf charger -> 0x1DC Bit20-30

### Take into account in VMS

- charge interlock state to avoid enabling main contactors while charging
- Limit current used by the motor (amps or Kwh):
    - EM57 delivers 80KwH ~= 250N/m at 100%, max requested torque should be capped based on the "Pack discharge current limit" provided by Orion BMS
- Limit current provided by the motor (regenerative breaking) (amps or KwH)
- Monitor error codes and failsafe statuses sent by Orion BMS

### Frame to be emitted by Orion BMS:



