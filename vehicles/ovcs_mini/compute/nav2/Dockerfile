# The OVCS Mini's Nav2: the framework's image with this vehicle's
# parameters and behaviour trees baked in. balenaOS has no host bind
# mounts, so the configuration ships in the image; the simulator
# (compose/local/simulation.yml) builds this same image and mounts
# ./config over it to try an edit without a rebuild.
#
# `latest` follows the framework's main branch. Pin to a `sha-<short>`
# tag when a framework change must not reach the car unreviewed.
FROM ghcr.io/open-vehicle-control-system/ovcs/nav2:latest

COPY config /opt/ovcs/config
