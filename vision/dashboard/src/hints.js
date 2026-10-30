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
      "Amplification of the sensor's signal for the latest image. It brightens a dark scene but adds noise, " +
      'and noise makes the two images harder to match.'
  },
  depthRate: {
    title: 'Depth rate',
    text:
      'Depth maps the unit computed in the last second. Each needs a left and right image, so it cannot exceed ' +
      'the cameras’ rate; well below it, the pipeline is the bottleneck (see GPU in the top bar).'
  },
  matched: {
    title: 'Matched pixels',
    text:
      'Share of pixels where the same point was found in both images, so with a depth. The others are black: ' +
      'too dark, plain surfaces with no texture, seen by one camera only, or dropped by the filters.'
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
      "How much a pixel's disparity changes from one depth map to the next, on average. On a still scene " +
      'nothing moves, so it is the matcher’s noise: the lower, the steadier the depth.'
  },
  sync: {
    title: 'Synchronisation',
    text:
      'Median time between the left and right captures of a pair. Matching assumes both images show the same ' +
      'instant; within 1 ms is healthy. Max is the worst of the recent pairs.'
  },
  alignment: {
    title: 'Row alignment',
    text:
      'After rectification a point should sit on the same row in both images. This is how many rows the right ' +
      'image is off, overall and in four bands from left to right. Past half a row the calibration no longer ' +
      'fits the cameras and matching suffers.'
  },
  sharpness: {
    title: 'Sharpness, right / left',
    text:
      "The right image's sharpness divided by the left's. Near 1 both cameras are focused alike; far from 1 " +
      'one of them is out of focus compared with the other.'
  },
  colourScale: {
    title: 'Colour scale',
    text:
      'How this video colours depth: the nearest red, through yellow and green, to blue at this distance and ' +
      'beyond. At ∞ the colours spread up to infinitely far. Only this video changes; the depth sent to ' +
      'ROS 2 does not.'
  },
  zenoh: {
    title: 'Zenoh',
    text: 'The link to the Zenoh router that carries the ROS 2 topics. Disconnected, nothing reaches ROS 2.'
  },
  hailo: {
    title: 'Hailo',
    text: 'The Hailo accelerator running object detection. Absent when the vehicle configures none.'
  },
  cpu: {
    title: 'CPU',
    text: 'Busy share of all processor cores over the last second.'
  },
  gpu: {
    title: 'GPU',
    text:
      "Share of each second spent in the stereo pipeline's GPU work, uploads and waits included. " +
      'Near 100 %, the pipeline cannot go faster and the depth rate drops below the cameras’.'
  }
}
