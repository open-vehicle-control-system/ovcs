# models

Compiled Hailo models (`.hef`) for the Mini's perception bridge.

## yolov8n.hef

COCO YOLOv8-nano from the Hailo model zoo, compiled for **HAILO8**
(the 26 TOPS AI HAT+, not the 13 TOPS Hailo-8L — a HEF is built for
one architecture and will not load on the other).

    https://hailo-model-zoo.s3.eu-west-2.amazonaws.com/ModelZoo/Compiled/v2.15.0/hailo8/yolov8n.hef

Input is 640x640x3 UINT8 NHWC. NMS runs **in-graph**
(`yolov8_nms_postprocess`, score 0.20 / IoU 0.70, 80 classes), which
is why `hailo_detect` decodes no anchors and runs no suppression of
its own — it reads `HAILO_NMS_BY_CLASS` output directly.

Measured on the device with `hailortcli benchmark`: 340 FPS hw-only,
177 FPS streaming, 3.33 ms hardware latency — against a stereo
pipeline running at ~15 Hz, so inference is not the constraint.

Checked in rather than fetched at build time so a firmware build is
reproducible offline, the same way the calibration YAMLs are. It is
5.1 MB; if more models land here, revisit whether they belong in the
image or on the data partition.

### Swapping the model

`yolov8s.hef` from the same model zoo path is the accuracy/speed step
up and has the identical input and output contract, so it is a
drop-in — change `:hef_path` in the vehicle's `:hailo_detector` opts.
Anything with a different input size or without in-graph NMS is not.
