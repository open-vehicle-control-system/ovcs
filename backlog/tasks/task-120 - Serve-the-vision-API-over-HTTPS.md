---
id: TASK-120
title: Serve the vision API over HTTPS
status: In Progress
assignee:
  - '@claude'
created_date: '2026-11-13T12:13:00Z'
updated_date: '2026-11-13T12:42:00Z'
labels:
  - vision
dependencies: []
ordinal: 88000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
The vision dashboard shows a camera's H.264 video by decoding it with WebCodecs (`VideoDecoder`, TASK-111), which a browser offers only in a secure context: HTTPS, or `localhost`. The vision unit serves the dashboard and its API over plain HTTP on port 4100, so a dashboard opened at `http://<vehicle>-vision.local:4100` cannot decode the video.

Design:
- The unit serves the endpoint over HTTPS on port 443, so `https://<vehicle>-vision.local` needs no port, with a self-signed certificate. A unit has no name a public authority would certify, and a key shipped in the firmware would be shared by every unit and readable in the image.
- The certificate is generated on the unit when the files the endpoint's `https:` options name are missing, before the endpoint starts (`VisionApi.Application`), and kept on the application partition (`/data/vision_api/`), so it is reused across reboots and firmware updates and the browser's exception holds. Key: EC P-256, quick to generate on the board. Its names: the unit's hostname and `<hostname>.local`. Valid from 2000-01-01 to 9999-12-31, RFC 5280's "no expiry": a unit starts before NTP sets its clock, so the validity cannot be counted from the generation time.
- It is built with the `x509` package. `nerves_hub_link` already ships it in every firmware, at the same version, and it has no dependencies. OTP's `:public_key` alone builds a certificate only from hand-written ASN.1 records, or with its test helpers, whose subject and extensions are fixed for test chains.
- Plain HTTP on port 80 and on port 4100, where the unit served it before, redirects every request to `https://<host>` with the same path, so old addresses and bookmarks keep working. `Plug.SSL` (`force_ssl`) is not used: its host is fixed in the configuration, which breaks access by IP address, and it would run inside the HTTPS endpoint rather than on ports of their own. No HSTS: it would pin the name to HTTPS for every port.
- The certificate path and the ports are the vision firmware's (`config/target.exs`); nothing is vehicle-specific.
- Development is unchanged: the API on `http://localhost:4101` and the Vite dev server on `http://localhost:5174`, both on `localhost`, a secure context.

Who else talks to the vision API: nothing in the repository but the dashboard, which the API serves itself and whose socket follows the page's scheme (`wss:` under HTTPS). The ROS 2 bridge reaches the unit through Zenoh, the VMS and infotainment through the Erlang mesh, and the `ovcs` CLI over SSH. The guides' `curl` and socket examples move to `https://` and `wss://`, checking the unit's certificate against a copy of it (`curl --cacert`). A program that called `http://<vehicle>-vision.local:4100` gets a redirect it must follow, and a WebSocket client must move to `wss://`: browsers do not follow redirects on a WebSocket.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 The unit serves the dashboard and its API over HTTPS on port 443, with a self-signed certificate generated at its first start
- [x] #2 The certificate survives a reboot: the same fingerprint after it
- [x] #3 A plain HTTP request on port 80 or 4100 is redirected to the same path over HTTPS on port 443
- [x] #4 Development keeps plain HTTP on localhost
- [x] #5 The vision guides use https and wss
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
On the VENTUNO Q (OVCS1): the certificate generated at the first start names ovcs1-vision and ovcs1-vision.local, is valid 2000-01-01 to 9999-12-31, and keeps its SHA-256 fingerprint across a reboot. Headless Chrome (certificate errors ignored) loads the dashboard as a secure context, with WebCodecs.

http://<unit>/ and http://<unit>:4100/<path> answer 301 to https://<unit>/<path>. curl --cacert with the unit's certificate, and Node.js with NODE_EXTRA_CA_CERTS joining the status channel over wss, accept it by name and refuse it without the copy.
<!-- SECTION:NOTES:END -->
