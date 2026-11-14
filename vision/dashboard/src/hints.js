/** What each figure on the page means, why it matters and what a bad value says, as `{ title, text }`. */
export const HINTS = {
  cameraRate: {
    title: 'Frame rate',
    text:
      'Images this camera delivered in the last second. A depth map needs one image from each camera, ' +
      'so the slower camera caps the depth rate. Below the configured rate, frames are being dropped.'
  },
  exposure: {
    title: 'Exposure',
    text:
      'How long the sensor gathered light for the latest image. Longer is brighter but blurs anything moving. ' +
      'Auto exposure lengthens it up to its maximum, then raises the gain.'
  },
  gain: {
    title: 'Analogue gain',
    text:
      "Amplification of the sensor’s signal for the latest image. It brightens a dark scene but adds noise, " +
      'and noise makes the two images harder to match.'
  },
  depthRate: {
    title: 'Depth rate',
    text:
      'Depth maps the unit computed in the last second. Each needs a left and right image, so it cannot exceed ' +
      'the cameras’ rate; well below it, the pipeline is the bottleneck (see Stereo load in the bottom bar).'
  },
  matched: {
    title: 'Matched pixels',
    text:
      'Share of pixels where the same point was found in both images, the only ones that can have a depth. ' +
      'The others are black: too dark, plain surfaces with no texture, seen by one camera only, or dropped by ' +
      'the filters.'
  },
  disparity: {
    title: 'Disparity',
    text:
      'How many pixels a point shifts between the left and right images, averaged over the matched pixels, ' +
      '± its spread. Near things shift more: the distance is focal length × camera spacing ÷ disparity.'
  },
  jitter: {
    title: 'Jitter',
    text:
      "How much a pixel’s disparity changes from one depth map to the next, on average. On a still scene " +
      'nothing moves, so it is the matcher’s noise: the lower, the steadier the depth.'
  },
  timing: {
    title: 'Timing',
    text:
      'Which camera starts its capture later, and by how much, as a median over the recent pairs; max is the ' +
      'worst. Matching assumes both images show the same instant: the unit warns when they drift apart.'
  },
  rows: {
    title: 'Rows',
    text:
      'After rectification a point sits on the same row in both images. This is how far the right image is from ' +
      'where the calibration puts it, the automatic row correction included, and the offset left in four bands ' +
      'from left to right. The unit asks for a new calibration when the rows drift, the correction grows large ' +
      'or the bands disagree, as when a camera turned.'
  },
  focus: {
    title: 'Focus',
    text:
      'Which camera is less sharp than the other, and by how much. The unit warns when their focus differs ' +
      'enough to cost matching; the softer camera shows the warning.'
  },
  brightness: {
    title: 'Brightness',
    text:
      'Which camera’s image is brighter than the other’s, and by how much, at the same exposure and gain. ' +
      'A camera much brighter than the other sees through a hazy, dirty or different lens: the unit warns, and ' +
      'that camera shows the warning.'
  },
  dropped: {
    title: 'Dropped',
    text:
      'The share of the pairs the cameras delivered over the last 10 s that never became depth, because the stereo ' +
      'work took longer than a frame. The unit warns past 5 %: lower the cameras’ frame rate or the stereo work.'
  },
  tooNear: {
    title: 'Too near',
    text:
      'The share of the matched pixels in the nearest band the depth measures, and the distance that range ' +
      'stops at. Anything nearer is out of range and matched wrongly: the unit warns when much of the scene ' +
      'is there. Move back, or widen the disparity range.'
  },
  colourScale: {
    title: 'Colour scale',
    text:
      'How this video colours depth: the nearest red, through yellow and green, to blue at this distance and ' +
      'beyond. At ∞ the colours spread up to infinitely far. Every dashboard on this unit shares it, and only ' +
      'this video changes; the depth the exporters publish, such as ROS 2’s, does not.'
  },
  ros2: {
    title: 'ROS 2',
    text:
      "The ROS 2 exporter's link to the Zenoh router that carries its topics. Disconnected, nothing reaches ROS 2. " +
      'Its page, under Exporters, lists the topics and their rates.'
  },
  calibration: {
    title: 'Calibration',
    text:
      'The unit has no calibration for its cameras, so it computes no depth. Calibrate them on the Calibration ' +
      'page: depth starts once a calibration is applied.'
  },
  connection: {
    title: 'Connection',
    text:
      "The dashboard's live link to the unit, which carries the statuses beside it and the previews. " +
      'Disconnected, the page shows nothing new until the link comes back.'
  },
  npu: {
    title: 'NPU',
    text:
      "The accelerator running the unit's inference, by kind, with its load: the share of the last second its pipelines spent inferring, summed over them. " +
      'On a Hexagon it counts the time the NPU spent executing; on a Hailo-8 the time from writing the input to reading the output, PCIe transfer included. ' +
      "Each pipeline's Inference step shows its mean time per frame. Starting while a backend prepares its model, red when one cannot run; none on a unit without one."
  },
  objects: {
    title: 'Objects',
    text:
      'Objects the detector found in the latest image, each outlined on the left video with its distance. ' +
      'An object with no depth in the middle of its box, such as one nearer than the depth can measure, is left out.'
  },
  stereoLoad: {
    title: 'Stereo load',
    text:
      'Share of each second the pairs spent at the device computing the stereo stages, from handing a pair over to ' +
      'its result: on the GPU, the upload of its images included, or on the processor cores in native code. At ' +
      '100 % a pair takes a whole frame and the depth rate drops below the cameras’. A warning shows from 97 %.'
  },
  distances: {
    title: 'No distances',
    text:
      'The detections and segmentation on this camera take their distances from the stereo depth, which needs the ' +
      'camera’s calibration and its pose: where it sits relative to the stereo pair. Calibrate it, then measure its ' +
      'position, under the camera in the menu’s Cameras section.'
  }
}
