"""Correct NetworkManager's channel-149 VHT center frequency on the AX210."""

import logging
import subprocess
import time

import dbus

DEVICE = "wlP1p1s0"
SUPPLICANT = "fi.w1.wpa_supplicant1"
PROPERTIES = "org.freedesktop.DBus.Properties"
NETWORK_MANAGER = "org.freedesktop.NetworkManager"
LOG = logging.getLogger("wifi_ap_fix")


def retry_preferred_profile(bus):
    """Retry once if boot reached the fallback before this service started."""
    manager = dbus.Interface(
        bus.get_object(NETWORK_MANAGER, "/org/freedesktop/NetworkManager"), NETWORK_MANAGER,
    )
    device_path = manager.GetDeviceByIpIface(DEVICE)
    device = bus.get_object(NETWORK_MANAGER, device_path)
    active_path = dbus.Interface(device, PROPERTIES).Get(
        f"{NETWORK_MANAGER}.Device", "ActiveConnection",
    )
    if active_path == "/":
        return False
    active = bus.get_object(NETWORK_MANAGER, active_path)
    name = dbus.Interface(active, PROPERTIES).Get(
        f"{NETWORK_MANAGER}.Connection.Active", "Id",
    )
    if name != "ovcs0-ap-fallback":
        return False
    settings = dbus.Interface(
        bus.get_object(NETWORK_MANAGER, "/org/freedesktop/NetworkManager/Settings"),
        f"{NETWORK_MANAGER}.Settings",
    )
    for path in settings.ListConnections():
        connection = dbus.Interface(
            bus.get_object(NETWORK_MANAGER, path), f"{NETWORK_MANAGER}.Settings.Connection",
        )
        values = connection.GetSettings()
        if (
            values["connection"]["id"] == "ovcs0-ap"
            and values.get("802-11-wireless", {}).get("band") == "a"
        ):
            manager.ActivateConnection(path, device_path, dbus.ObjectPath("/"))
            LOG.info("Retrying the preferred AP now that the correction service is ready")
            return True
    return False


def correct_network(bus, path):
    network = bus.get_object(SUPPLICANT, path)
    properties = dbus.Interface(network, PROPERTIES)
    values = properties.Get(f"{SUPPLICANT}.Network", "Properties")
    # Supplicant exposes these network properties as strings. Only touch
    # the invalid center generated for an AP on primary channel 149.
    if not (
        str(values.get("mode")) == "2"
        and str(values.get("frequency")) == "5745"
        and str(values.get("vht_center_freq1")) == "5770"
    ):
        return False
    properties.Set(
        f"{SUPPLICANT}.Network",
        "Properties",
        dbus.Dictionary({"vht_center_freq1": dbus.Int32(5775)}, signature="sv"),
    )
    return True


def maintain(bus):
    # Set the limit before enabling a corrected network. Repeat after a
    # driver reset; the kernel still enforces its own regulatory limits.
    info = subprocess.run(
        ["iw", "dev", DEVICE, "info"], capture_output=True, text=True, check=False,
    )
    if info.returncode:
        return
    if "txpower 6.00 dBm" not in info.stdout:
        subprocess.run(["iw", "dev", DEVICE, "set", "txpower", "limit", "600"], check=True)
        LOG.info("Limited %s transmit power to 6 dBm", DEVICE)

    root = dbus.Interface(bus.get_object(SUPPLICANT, "/fi/w1/wpa_supplicant1"), SUPPLICANT)
    interface = bus.get_object(SUPPLICANT, root.GetInterface(DEVICE))
    properties = dbus.Interface(interface, PROPERTIES)
    for path in properties.Get(f"{SUPPLICANT}.Interface", "Networks"):
        if correct_network(bus, path):
            dbus.Interface(interface, f"{SUPPLICANT}.Interface").SelectNetwork(path)
            LOG.info("Corrected channel 149 / 80 MHz center to 5775 MHz")


def main():
    logging.basicConfig(level=logging.INFO, format="%(name)s: %(message)s")
    last_error = None
    retried = False
    while True:
        try:
            bus = dbus.SystemBus()
            maintain(bus)
            if not retried:
                retried = retry_preferred_profile(bus)
            last_error = None
        except (dbus.DBusException, subprocess.CalledProcessError) as error:
            # Avoid printing network properties: they can contain credentials.
            name = type(error).__name__
            if name != last_error:
                LOG.warning("Waiting for the AP interface (%s)", name)
                last_error = name
        time.sleep(2)


if __name__ == "__main__":
    main()
