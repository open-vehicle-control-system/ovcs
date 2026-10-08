#!/usr/bin/env python3
"""Hold a force-feedback wheel's centring spring while the joy node runs.

Usage: joy_centring /dev/input/jsN strength

Loads a spring effect, `strength` in (0, 1], on the joystick's event
device and keeps it: the kernel drops an effect when the file that
loaded it closes. The driver's own autocentre stops at a quarter of
the spring's strength. A wheel unplugged and plugged back gets the
spring again.
"""
import fcntl
import glob
import os
import struct
import sys
import time

EV_FF = 0x15
FF_SPRING = 0x53
FF_GAIN = 0x60
# _IOW('E', 0x80, struct ff_effect), a 48-byte struct on 64-bit Linux.
EVIOCSFF = 0x40304580


def event_device(joystick):
    paths = glob.glob(f"/sys/class/input/{os.path.basename(joystick)}/device/event*")
    return f"/dev/input/{os.path.basename(paths[0])}" if paths else None


def event(code, value):
    # struct input_event: timeval (two longs), type, code, value.
    return struct.pack("llHHi", 0, 0, EV_FF, code, value)


def load_spring(fd, strength):
    os.write(fd, event(FF_GAIN, 0xFFFF))
    saturation, coefficient = int(0xFFFF * strength), int(0x7FFF * strength)
    # Per axis: right and left saturation and coefficient, deadband, centre.
    condition = struct.pack("HHhhHh", saturation, saturation, coefficient, coefficient, 0, 0)
    # type, id (-1: new), direction, trigger, replay, then the union at 16.
    header = struct.pack("HhHHHHH", FF_SPRING, -1, 0, 0, 0, 0, 0) + b"\0\0"
    effect = bytearray(header + condition * 2 + b"\0" * 8)
    fcntl.ioctl(fd, EVIOCSFF, effect)
    os.write(fd, event(struct.unpack_from("h", effect, 2)[0], 1))


def main():
    joystick, strength = sys.argv[1], min(max(float(sys.argv[2]), 0.0), 1.0)
    while True:
        device = event_device(joystick)
        try:
            fd = os.open(device, os.O_RDWR)
        except (OSError, TypeError):
            time.sleep(1)
            continue

        try:
            load_spring(fd, strength)
            print(f"joy_centring: spring at {strength:.0%} on {device}", flush=True)
            # Writing fails once the wheel is gone.
            while True:
                time.sleep(1)
                os.write(fd, event(FF_GAIN, 0xFFFF))
        except OSError:
            time.sleep(1)
        finally:
            os.close(fd)


if __name__ == "__main__":
    main()
