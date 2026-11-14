---
title: Road segmentation
description: Classify each part of a camera's image and sort the stereo points it sees into road and off-road clouds for a navigation stack.
---

Sort the stereo points a camera of its own sees into road and off-road clouds, for a navigation stack. A segmentation pipeline classifies each part of the camera's image among the 19 Cityscapes classes, `road` among them. You need an Arduino VENTUNO Q, whose NPU runs the model, and a camera of its own ([A camera of its own](./cameras.md)). The clouds also need the camera's calibration and pose.

## Declare the pipeline

The pipeline takes a camera source only, `{:camera, name}` or `{:camera, name, output}`, in colour. The stereo pair's images are grey, and road models are trained on colour.

The `:qnn_segmenter` component runs it on the VENTUNO Q's NPU, in the `qnn_segment` Port behind `VisionCore.Segmentation.Backend.Qnn`. It runs its model as the detection Port does ([On the VENTUNO Q's NPU](./detection.md#on-the-ventuno-qs-npu)). The board generates its context binary on first boot, into `/data/vision/qnn/<name>`, and the Port holds a power vote set by `performance:` and `rpc_polling_us:`.

With the OVCS1 reference vehicle's colour camera, `:center`, and its `:half` output, it reads as below; it works the same with your camera:

```elixir
{:qnn_segmenter,
 name: :scene,
 source: {:camera, :center, :half},
 dlc_path: Application.app_dir(:<vehicle>, "priv/models/ffnet_122ns_lowres.dlc")}
```

## What it does

- **Name.** `:name` is required and follows the detection pipelines' rule, in their namespace and the cameras': no detector, segmenter or camera shares it.
- **Band.** The model sees a 2:1 band along the frame's bottom, where the road is: the frame's full width, and half that in height. `band_top`, a fraction of the frame's height from 0 to 1, moves it up. At 1, the default, the band touches the frame's bottom.
- **Input.** The Port resizes the band to the model's input, 1024 × 512 for FFNet. It shrinks a wider band and enlarges a narrower one, such as a half-resolution HQ Camera's 1014 × 507. It gives each cell of the model's output grid a class: 256 × 128 cells for FFNet.
- **Rate.** `segment_every_n` segments one camera frame in `n`: the `n`th, `2n`th, `3n`th… One band is with the backend at a time, as for [a detection pipeline on a camera of its own](./detection.md#detect-on-a-camera-of-its-own).
- **Model.** `dlc_path` names a DLC whose input is a `[1, H, W, 3]` uint8 RGB image. It is unquantised, or quantised with a scale of 1/255 and an offset of 0: either takes the pixel values as they are. Its output scores each cell for as many classes as `labels` names, the 19 Cityscapes classes by default. `qnn_segment` refuses another model at start, naming what does not match.
- **Road.** `road_classes` names the classes that count as road, `["road"]` by default.
- **Clouds.** The stereo pair captured closest to the frame is matched with it, as for [a detection pipeline on a camera of its own](./detection.md#detect-on-a-camera-of-its-own). Its depth is projected into the camera's image, with the same `reprojection_stride` and `pair_wait_ms`. Each projected point takes the class of the cell it lands in. The road points and the off-road points are two clouds, in the stereo left optical frame.
- **No clouds.** A frame without a matched pair, or on a camera without a calibration or a pose, has its label grid and no clouds.
- **Calibration.** The pipeline reads the camera's calibration and pose at start. [Calibration and pose](./cameras.md#calibration-and-pose) says when a committed calibration reaches the label grid and the clouds.
- **What it publishes.** The ROS 2 exporter publishes the label grid as a `mono8` image of class ids. It publishes the two clouds as `PointCloud2` ([What leaves the unit](./data_flow.md#what-leaves-the-unit)). The API's `segmentation:<name>` channel carries the grid and the band it covers ([Segmentation](./channels.md#segmentation)). It sends at most `max_hz` (5) a second, one at a time, each once the client acknowledges the one before.

## Settings

A pipeline's settings are options of its segmenter component and vision parameters, `<name>.<step>.<setting>`. The option is the value the pipeline starts with, and the parameter's default. The live ones change while the unit runs, from the next frame ([Change a parameter](./api.md#change-a-parameter)). A value outside a setting's range is refused, at start and at a change.

| Parameter | Kind | Default | Values | Meaning |
|---|---|---|---|---|
| `input.segment_every_n` | live | 1 | 1 to 1000 | Segments one frame in `n`. |
| `input.band_top` | live | 1 | 0 to 1 | The band's top, as a share of the frame's height. |
| `inference.model` | build | | | The model file the NPU runs. |
| `inference.classes` | build | 19 | | Classes the model scores, as many as `labels` names. |
| `inference.performance` | build | `burst` | | The NPU's performance profile. |
| `inference.rpc_polling_us` | build | 0 | | The RPC polling of its power vote. |
| `inference.infer_timeout_ms` | build | 2000 | | Longest wait for an inference before the program is restarted. |
| `classes.road_classes` | build | `road` | | The classes that count as road. |
| `classes.reprojection_stride` | live | 3 | 1 to 32 | Every how many pixels and rows of the depth are projected. |
| `classes.pair_wait_ms` | live | 500 | 0 to 60000 | The longest a label grid waits for its pair. |

The build parameters are fixed when the pipeline starts: change them in your composer.

## The model

The road model the OVCS1 reference vehicle runs is FFNet-122NS-LowRes, quantised w8a8 for QNN by Qualcomm AI Hub.

> [!WARNING]
> FFNet-122NS-LowRes's weights are for non-commercial use only. FFNet's code is BSD-3-Clause, but the weights are trained on Cityscapes, whose terms allow non-commercial use only. A vehicle used commercially needs a road model trained on data you may use commercially.

`mise run fetch-models` downloads it as `vehicles/ovcs1/priv/models/ffnet_122ns_lowres.dlc`. It prints the model's licence, which `scripts/models.tsv` records, before the download.

## See also

- [A camera of its own](./cameras.md): the camera, its calibration and its pose.
- [Object detection](./detection.md): detection pipelines and the accelerator's load.
- [Vision channels](./channels.md#segmentation): the segmentation channel.
