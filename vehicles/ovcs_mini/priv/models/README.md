# models

Compiled Hailo models (`.hef`) for the Mini's perception bridge.

**Nothing in this directory is committed.** Run

    mise run fetch-models

to download and verify them. `scripts/models.tsv` is the manifest —
URL, sha256 and licence per model.

## Why they are fetched rather than vendored

OVCS is MIT licensed. YOLOv8's weights are Ultralytics **AGPL-3.0**,
and the two do not compose in that direction: the MIT grant tells
downstream users they may use this without source-disclosure
obligations, which AGPL does not permit anyone to grant on its behalf.
Shipping the weights here would make a promise the licence cannot keep,
and would quietly hand an obligation to anyone who cloned the repo.

An earlier version of this file argued for checking the model in, so a
firmware build would be reproducible offline. That tradeoff is real and
it has not gone away — you now need network access and one command
before a first build. The licence is why it changed anyway.

See `docs/ros_perception_detection.md` for the licensing note in full,
including the permissively licensed models that are drop-in candidates.

## nanodet_repvgg.hef — the default

NanoDet-RepVGG from the Hailo model zoo, **Apache-2.0**, which is why
it is the default: nothing about it conflicts with this repository's
MIT licence.

It is a drop-in for the YOLOv8 model below, and that was verified from
the HEF rather than assumed. It carries the same in-graph NMS net flow
(`HAILO_NET_FLOW_YOLOV8_NMS`), so the output is the same
`HAILO_NMS_BY_CLASS` layout `hailo_detect` already reads; and
`hailo_detect` derives both the input size and the class count from the
HEF at runtime, so neither is hardcoded to YOLOv8's.

Two things still need a Hailo-8 to confirm: that it loads and detects
sensibly, and the score threshold — 0.4 was measured against yolov8n,
not this. Failure is loud and harmless: `hailo_detect` logs and exits,
the backend answers `{:error, :unavailable}`, and stereo depth is
unaffected.

`yolox_tiny` is also Apache-2.0 and also in the zoo, but is **not** a
drop-in — it uses `HAILO_NET_FLOW_YOLOX_NMS`, a different postprocess
op.

## yolov8n.hef — the AGPL alternative

Selected with `OVCS_HAILO_MODEL=yolov8n`. Its accuracy at this
resolution is the measured baseline, and it is the right choice for
anyone holding an Ultralytics Enterprise licence.


COCO YOLOv8-nano from the Hailo model zoo, compiled for **HAILO8**
(the 26 TOPS AI HAT+, not the 13 TOPS Hailo-8L — a HEF is built for
one architecture and will not load on the other).

Input is 640x640x3 UINT8 NHWC. NMS runs **in-graph**
(`yolov8_nms_postprocess`, score 0.20 / IoU 0.70, 80 classes), which
is why `hailo_detect` decodes no anchors and runs no suppression of
its own — it reads `HAILO_NMS_BY_CLASS` output directly.

Measured on the device with `hailortcli benchmark`: 340 FPS hw-only,
177 FPS streaming, 3.33 ms hardware latency — against a stereo
pipeline running at ~15 Hz, so inference is not the constraint.

## Running without a model

Nothing breaks. `Inference.Hailo` checks for the file before opening
its Port and answers `{:error, :unavailable}` when it is absent;
`Inference.Dnn` does the same for its `.onnx`. Both log once, and the
stereo depth pipeline runs on regardless — losing detections is
acceptable, taking depth down with it is not.

## Adding another

Add it to `scripts/models.tsv` — destination, sha256, licence, URL —
and set `OVCS_HAILO_MODEL` to its basename.

What has to hold: a **square 3-channel input** and **in-graph NMS
producing `HAILO_NMS_BY_CLASS`**. Size and class count do not, since
`hailo_detect` reads both off the HEF. `yolov8s.hef` from the same zoo
path is the accuracy step up and satisfies all of it. A model with a
different NMS net flow, or none, does not — see
`docs/ros_perception_detection.md` for what a swap would cost then.

Checking is cheap and needs no device:

    strings <model>.hef | grep -oE 'HAILO_NET_FLOW_[A-Z0-9_]+'
