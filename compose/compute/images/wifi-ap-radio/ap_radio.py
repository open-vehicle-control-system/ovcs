"""Keep the compute node's access point on its intended radio settings.

NetworkManager rewrites the AP network in the host's wpa_supplicant every
time it activates the profile, and a driver reset drops the transmit-power
limit, so both corrections are re-checked every two seconds:

* NetworkManager 1.52 gives an 80 MHz AP on channel 149 the VHT center
  5770 MHz, which is not a valid 80 MHz channel; the supplicant's network
  is corrected to 5775 MHz over D-Bus and re-selected.
* The transmit power is limited to AP_TX_POWER_DBM (see the AP keyfile for
  why 6 dBm); the kernel still enforces its regulatory limits on top.

NetworkManager gives up on the AP after a failed start, which happens when
the AX210 has reset its regulatory domain to WORLD. While the interface is
not running AP_CONNECTION, the AP is restarted every RESTART_INTERVAL_S,
each time after a scan, from which the driver learns the country again.
"""

import logging
import os
import subprocess
import time

import dbus

INTERFACE = os.environ.get("AP_IFACE", "wlP1p1s0")
TX_POWER_DBM = int(os.environ.get("AP_TX_POWER_DBM", "6"))
AP_CONNECTION = os.environ.get("AP_CONNECTION", "ovcs0-ap")
RESTART_INTERVAL_S = 60
SCAN_LEAD_S = 6

CHANNEL_149_MHZ = "5745"
WRONG_CENTER_MHZ = "5770"
CENTER_MHZ = 5775
AP_MODE = "2"

SUPPLICANT = "fi.w1.wpa_supplicant1"
NETWORK_MANAGER = "org.freedesktop.NetworkManager"
PROPERTIES = "org.freedesktop.DBus.Properties"
LOG = logging.getLogger("wifi_ap_radio")


def limit_tx_power():
    """Return False while the interface does not exist yet."""
    info = subprocess.run(
        ["iw", "dev", INTERFACE, "info"], capture_output=True, text=True, check=False,
    )
    if info.returncode:
        return False
    if f"txpower {TX_POWER_DBM}.00 dBm" not in info.stdout:
        subprocess.run(
            ["iw", "dev", INTERFACE, "set", "txpower", "limit", str(TX_POWER_DBM * 100)],
            check=True,
        )
        LOG.info("Limited %s transmit power to %d dBm", INTERFACE, TX_POWER_DBM)
    return True


def has_wrong_center(properties):
    # The supplicant exposes network properties as strings.
    values = properties.Get(f"{SUPPLICANT}.Network", "Properties")
    return (
        str(values.get("mode")) == AP_MODE
        and str(values.get("frequency")) == CHANNEL_149_MHZ
        and str(values.get("vht_center_freq1")) == WRONG_CENTER_MHZ
    )


def correct_center(bus):
    root = dbus.Interface(bus.get_object(SUPPLICANT, "/fi/w1/wpa_supplicant1"), SUPPLICANT)
    interface = bus.get_object(SUPPLICANT, root.GetInterface(INTERFACE))
    networks = dbus.Interface(interface, PROPERTIES).Get(f"{SUPPLICANT}.Interface", "Networks")
    for path in networks:
        properties = dbus.Interface(bus.get_object(SUPPLICANT, path), PROPERTIES)
        if not has_wrong_center(properties):
            continue
        properties.Set(
            f"{SUPPLICANT}.Network",
            "Properties",
            dbus.Dictionary({"vht_center_freq1": dbus.Int32(CENTER_MHZ)}, signature="sv"),
        )
        dbus.Interface(interface, f"{SUPPLICANT}.Interface").SelectNetwork(path)
        LOG.info("Corrected the channel 149 / 80 MHz center to %d MHz", CENTER_MHZ)


class Restarter:
    """Restart AP_CONNECTION when the interface is running anything else."""

    def __init__(self):
        self.restart_at = None

    def check(self, bus):
        manager = dbus.Interface(
            bus.get_object(NETWORK_MANAGER, "/org/freedesktop/NetworkManager"), NETWORK_MANAGER,
        )
        device_path = manager.GetDeviceByIpIface(INTERFACE)
        device = bus.get_object(NETWORK_MANAGER, device_path)
        if active_connection_id(bus, device) == AP_CONNECTION:
            self.restart_at = None
            return
        now = time.monotonic()
        if self.restart_at is None:
            dbus.Interface(device, f"{NETWORK_MANAGER}.Device.Wireless").RequestScan({})
            self.restart_at = now + SCAN_LEAD_S
            LOG.warning("%s is not running %s; scanning before a restart", INTERFACE, AP_CONNECTION)
        elif now >= self.restart_at:
            manager.ActivateConnection(ap_connection_path(bus), device_path, dbus.ObjectPath("/"))
            self.restart_at = now + RESTART_INTERVAL_S
            LOG.info("Restarting %s", AP_CONNECTION)


def active_connection_id(bus, device):
    path = dbus.Interface(device, PROPERTIES).Get(f"{NETWORK_MANAGER}.Device", "ActiveConnection")
    if path == "/":
        return None
    active = bus.get_object(NETWORK_MANAGER, path)
    return dbus.Interface(active, PROPERTIES).Get(f"{NETWORK_MANAGER}.Connection.Active", "Id")


def ap_connection_path(bus):
    settings = dbus.Interface(
        bus.get_object(NETWORK_MANAGER, "/org/freedesktop/NetworkManager/Settings"),
        f"{NETWORK_MANAGER}.Settings",
    )
    for path in settings.ListConnections():
        connection = dbus.Interface(
            bus.get_object(NETWORK_MANAGER, path), f"{NETWORK_MANAGER}.Settings.Connection",
        )
        if connection.GetSettings()["connection"]["id"] == AP_CONNECTION:
            return path
    raise dbus.DBusException(f"no connection named {AP_CONNECTION}")


def main():
    logging.basicConfig(level=logging.INFO, format="%(name)s: %(message)s")
    restarter = Restarter()
    last_error = None
    while True:
        try:
            bus = dbus.SystemBus()
            # The limit goes on before a corrected network is selected.
            if limit_tx_power():
                restarter.check(bus)
                correct_center(bus)
            last_error = None
        except (dbus.DBusException, subprocess.CalledProcessError) as error:
            # Only the type: network properties can contain credentials.
            name = type(error).__name__
            if name != last_error:
                LOG.warning("Waiting for the AP interface (%s)", name)
                last_error = name
        time.sleep(2)


if __name__ == "__main__":
    main()
