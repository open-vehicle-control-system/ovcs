# Wi-Fi firmware for the host kernel — see ../host/README.md.
#
# balenaOS ships the iwlwifi *driver* but its linux-firmware set stops
# at the 9260, so the AX210 in the Pi 5's PCIe slot enumerates, probes,
# and gives up:
#
#   iwlwifi 0001:01:00.0: Detected Killer(R) Wi-Fi 6E AX1675x (210NGW)
#   iwlwifi 0001:01:00.0: Direct firmware load for
#       iwlwifi-ty-a0-gf-a0-89.ucode failed with error -2
#   iwlwifi 0001:01:00.0: no suitable firmware found!
#   iwlwifi 0001:01:00.0: minimum version required: iwlwifi-ty-a0-gf-a0-77
#
# The host rootfs is read-only with no package manager, so the fix is
# balenaOS's extra-firmware feature: the kernel's firmware_class.path
# already points at a named volume, and the label below mounts it here
# as /extra-firmware. Needs balenaOS >= 6.10.7 / supervisor >= 17.5.2.
#
# Both blobs are required. The .ucode alone binds the driver but the
# radio never starts — the PNVM carries the per-SKU regulatory and RF
# tables, and iwlwifi logs "loaded PNVM version" once it has them.
#
# balena's own bh.cr/balena_os/linux-firmware-aarch64 block does the
# same job by shipping the whole linux-firmware tree. 1.7 MB of two
# named files is kinder to OTA deltas on a vehicle.
#
# Pinned to a linux-firmware tag rather than HEAD, and checksummed, so
# the build fails loudly instead of quietly shipping a different blob.
FROM alpine:3.22

ARG LF_TAG=20260810
ARG LF_BASE=https://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git/plain/intel/iwlwifi

RUN apk add --no-cache curl \
 && mkdir -p /firmware \
 && curl -sfLo /firmware/iwlwifi-ty-a0-gf-a0-89.ucode "$LF_BASE/iwlwifi-ty-a0-gf-a0-89.ucode?h=$LF_TAG" \
 && curl -sfLo /firmware/iwlwifi-ty-a0-gf-a0.pnvm     "$LF_BASE/iwlwifi-ty-a0-gf-a0.pnvm?h=$LF_TAG" \
 && printf '%s  %s\n' \
      9c63b42020d69598af746b7e265427f459ab773f1e31969d861e3e7b5fa30de4 /firmware/iwlwifi-ty-a0-gf-a0-89.ucode \
      1059f93a225e5c644d7c9c49302277b102f532b34672ef046c458befc1675fbb /firmware/iwlwifi-ty-a0-gf-a0.pnvm \
    | sha256sum -c -

# The kernel asks for bare filenames, so they land at the volume root.
# iwlwifi probes long before balenaEngine starts containers, so the
# first deploy only stages the files — the reboot is what binds them.
#
# Then idle instead of exiting. The work is a one-shot, but a service
# that exits is one the supervisor keeps trying to bring back, and no
# `restart:` value avoids that (see ../docker-compose.yml). Staying up
# costs an idle `tail` and makes the service's state legible: running
# means the firmware is staged. `tail -f /dev/null` rather than
# `sleep infinity` because busybox `sleep` does not take `infinity`.
CMD ["sh", "-c", "cp -v /firmware/* /extra-firmware/ && echo 'firmware staged; reboot to bind iwlwifi' && exec tail -f /dev/null"]
