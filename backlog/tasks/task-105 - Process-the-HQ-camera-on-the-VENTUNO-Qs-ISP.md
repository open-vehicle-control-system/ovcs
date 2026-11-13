---
id: TASK-105
title: Process the HQ camera on the VENTUNO Q's ISP and hardware encoders
status: In Progress
assignee:
  - '@claude'
created_date: '2026-11-12 14:00'
labels:
  - vision
dependencies:
  - TASK-94
ordinal: 84000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
`v4l2_capture` captures the IMX477's raw Bayer on the mainline `qcom-camss` RDI path and does every ISP step on the CPU. At 2028 × 1520 and 35 fps that costs about 2.4 of the VENTUNO Q's 8 cores: about 2 for the conversion (19.7 ms × 3 threads per frame) and about 0.5 for the 9 MB per frame written to the Port. The SoC has an ISP (Qualcomm Spectra) that could demosaic, correct and scale in hardware, and give two output sizes of one frame for inference and viewing.

To find out first: the exact SoC and what Arduino's own image offers for cameras; whether mainline `qcom-camss` or its pending series expose the ISP path for it; what Qualcomm's proprietary stack (CamX, `qtiqmmfsrc`) needs, under which licence, and whether an IMX477 tuning exists for it; libcamera's GPU-accelerated software ISP on the Adreno as an alternative. Then a spike on the most promising option. `v4l2_capture`'s `Processor` trait (TASK-94) takes the raw frame, the CPU's tone table and its thread count: an ISP processor changes the trait's input and the loop's dequeue, not the scaling, the framing, the writer or the Elixir side.

The SoC also has hardware encoders beside the ISP: a JPEG encoder, usually reached only through Qualcomm's camera stack, and a video encoder (Venus or Iris) that mainline Linux drives through V4L2 on several Qualcomm SoCs. H.264 or H.265 of the HQ camera's 2028 × 1520 at 30 fps on the video encoder would cost almost no CPU and roughly a tenth of the bandwidth of a JPEG stream (about 13 MB/s at quality 80); ROS 2 carries it (`ffmpeg_image_transport`, Foxglove's `CompressedVideo`) and browsers play it, but each frame depends on earlier ones, so a viewer needs the stream from a keyframe and some ROS 2 tools take only JPEG. To find out: whether the VENTUNO Q's kernel ships `venus`/`iris` for this SoC, which formats, sizes and rates it encodes, and its latency.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 The options are documented with sources, effort and what each needs, and one is chosen
- [ ] #2 A spike on the unit measures the chosen option's CPU and rate at 2028 × 1520, 35 fps, against the software path
- [ ] #3 The hardware video and JPEG encoders' support on the VENTUNO Q's kernel is documented, and if the video encoder works, a spike streams the HQ camera's image as H.264 or H.265 to ROS 2 and the dashboard, its CPU, bandwidth and latency measured against the JPEG stream
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Findings (November 2026), on the unit and upstream:

- The SoC is a QCS8275 (QCS8300 family), on our Linux 7.3.1. `qcom-camss` binds it with raw dump paths only (`msm_vfeN_rdiM`): `qcs8300_resources` reuses SA8775P's VFE resources, RDI by construction. Qualcomm's downstream device tree lists 2 IFE 692, 2 SFE-lite, 5 IFE-lite, an ICP and one IPE, and no BPS or OPE.
- Upstream processing work targets other SoCs: the offline OPE engine (Agatti, Shikra; v14 posted 2026-11, not merged), PIX on CSID/VFE-340 (Agatti, merged in 7.2, Bayer out), an ICP/BPS/IPE RFC for x1e80100. Nothing targets the IFE 6xx pixel path ([kernel-topics PR 2223](https://github.com/qualcomm-linux/kernel-topics/pull/2223), [OPE series](https://ratatoskr.run/linux-media/2026/11/17878708/t)).
- Qualcomm's CamX stack drives the ISP through an out-of-tree kernel driver ([camera-driver](https://github.com/qualcomm-linux/camera-driver)) and closed userspace and firmware (`LicenseRef-LICENSE.qcom-2`), with the VENTUNO Q's slots set up for the IMX577 and no IMX477 tuning: not usable on Nerves.
- libcamera 0.8's GPU software ISP (GLES via EGL, [libcamera](https://gitlab.freedesktop.org/camera/libcamera)) runs on the Adreno 623 our system enables, but gives RGB at one size without denoise; NV12 and a second size would be a patch of our own. The GPU also computes the stereo depth (about 28 ms a pair at 30 Hz), so it would trade CPU for depth time.
- The video codec works: `qcom-iris` with `qcom/vpu/vpu30_p4_s6.mbn` from linux-firmware encodes 2032 × 1520 H.264 at 265 fps with almost no CPU (TASK-111).

Chosen: the colour conversion stays on the CPU; the Iris encoder takes the JPEG encode's place for streaming (TASK-111), and the colour path writes NV12 for it directly. Revisit when upstream targets the IFE 6xx pixel path, or after measuring the GPU's spare time during stereo.
<!-- SECTION:NOTES:END -->
