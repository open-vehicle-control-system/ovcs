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

## yolov8n.hef

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

## Swapping the model

`yolov8s.hef` from the same model zoo path is the accuracy/speed step
up and has the identical input and output contract, so it is a
drop-in — add it to `scripts/models.tsv` and change `:hef_path` in the
vehicle's `:hailo_detector` opts. Anything with a different input size
or without in-graph NMS is not.
