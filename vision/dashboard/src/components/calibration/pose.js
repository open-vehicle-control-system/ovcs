import { formatNumber } from '../../status.js'

const DEGREES = 180 / Math.PI

// Rounded to a tenth, so that a value shown as 0 reads as one, whatever its sign.
const tenth = (value) => Math.round(value * 10) / 10 + 0

const signed = (value, positive, negative, unit) => {
  const rounded = tenth(value)
  return `${formatNumber(Math.abs(rounded))}${unit} ${rounded < 0 ? negative : positive}`
}

/**
 * Where the camera sits from the stereo left camera, in metres, along the left camera's rectified axes: x right, y down,
 * z forward. The pose maps a point of that frame into the camera's, `p_camera = R p_left + t`, so the camera's centre
 * is at −Rᵀ t.
 */
export function cameraPosition({ rotation, translation }) {
  return [0, 1, 2].map(
    (axis) => -(rotation[axis] * translation[0] + rotation[3 + axis] * translation[1] + rotation[6 + axis] * translation[2])
  )
}

/**
 * How the camera is turned from the stereo left camera, in degrees: its yaw about the left camera's down axis, then
 * its pitch about its right axis, then its roll about its optical axis. Positive is right, up and clockwise, seen from
 * behind the camera.
 */
export function cameraTurn({ rotation }) {
  const [, r01, , , r11, , r20, r21, r22] = rotation
  return {
    yaw: Math.atan2(r20, r22) * DEGREES,
    pitch: Math.asin(Math.max(-1, Math.min(1, -r21))) * DEGREES,
    roll: Math.atan2(r01, r11) * DEGREES
  }
}

/** The camera's position from the left camera in words, in millimetres; a dash without a pose. */
export function positionText(pose) {
  if (!pose) return '–'
  const [right, down, forward] = cameraPosition(pose).map((metres) => metres * 1000)
  return [signed(right, 'right', 'left', ' mm'), signed(down, 'down', 'up', ' mm'), signed(forward, 'forward', 'back', ' mm')].join(', ')
}

/** How the camera is turned from the left camera in words; a dash without a pose. */
export function turnText(pose) {
  if (!pose) return '–'
  const { yaw, pitch, roll } = cameraTurn(pose)
  return [signed(yaw, 'right', 'left', '°'), signed(pitch, 'up', 'down', '°'), signed(roll, 'clockwise', 'anticlockwise', '°')].join(', ')
}

/** The distance between the camera and the left camera; a dash without a pose. */
export const distanceText = (pose) => (pose ? `${formatNumber(pose.distanceMm)} mm` : '–')

/** The figures a person checks against the hardware, with a ruler and by eye. */
export const poseFacts = (pose) => [
  { label: 'Position from the left camera', value: positionText(pose) },
  { label: 'Distance to the left camera', value: distanceText(pose) },
  { label: 'Turned (yaw, pitch, roll)', value: turnText(pose) }
]
