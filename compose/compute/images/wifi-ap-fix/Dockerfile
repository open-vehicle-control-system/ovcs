FROM debian:bookworm-slim

RUN apt-get update \
    && apt-get install -y --no-install-recommends python3 python3-dbus iw \
    && rm -rf /var/lib/apt/lists/*

COPY fix_ap.py /usr/local/bin/fix_ap.py
CMD ["python3", "-u", "/usr/local/bin/fix_ap.py"]
