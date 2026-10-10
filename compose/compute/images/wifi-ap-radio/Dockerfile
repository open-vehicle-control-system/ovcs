# Keeps the access point's channel center and transmit power where the AP
# keyfile (../../host/system-connections/ovcs0-ap.nmconnection.example)
# puts them; see ap_radio.py. Host networking, NET_ADMIN and the host
# D-Bus socket are set in ../../docker-compose.yml.
FROM debian:bookworm-slim

RUN apt-get update \
    && apt-get install -y --no-install-recommends python3 python3-dbus iw \
    && rm -rf /var/lib/apt/lists/*

COPY ap_radio.py /usr/local/bin/ap_radio.py
CMD ["python3", "-u", "/usr/local/bin/ap_radio.py"]
