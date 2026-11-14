import { describe, it, expect } from 'vitest'
import { positionText, turnText } from '../calibration/pose.js'

const radians = (degrees) => (degrees * Math.PI) / 180

// Rotations of the camera's axes in the left camera's frame: x right, y down, z forward.
const aboutX = (degrees) => {
  const [cos, sin] = [Math.cos(radians(degrees)), Math.sin(radians(degrees))]
  return [1, 0, 0, 0, cos, -sin, 0, sin, cos]
}
const aboutY = (degrees) => {
  const [cos, sin] = [Math.cos(radians(degrees)), Math.sin(radians(degrees))]
  return [cos, 0, sin, 0, 1, 0, -sin, 0, cos]
}
const aboutZ = (degrees) => {
  const [cos, sin] = [Math.cos(radians(degrees)), Math.sin(radians(degrees))]
  return [cos, -sin, 0, sin, cos, 0, 0, 0, 1]
}
const transposed = (matrix) => [0, 1, 2].flatMap((column) => [matrix[column], matrix[3 + column], matrix[6 + column]])

// The pose of a camera whose axes are `orientation` in the left camera's frame and whose centre is at `position`, in metres.
const placed = (orientation, position) => {
  const rotation = transposed(orientation)
  const translation = [0, 1, 2].map(
    (row) => -(rotation[row * 3] * position[0] + rotation[row * 3 + 1] * position[1] + rotation[row * 3 + 2] * position[2])
  )
  return { rotation, translation }
}

describe('a camera pose in words', () => {
  it.each([
    ['turned right', aboutY(4), '4.0° right, 0.0° up, 0.0° clockwise'],
    ['turned left', aboutY(-3), '3.0° left, 0.0° up, 0.0° clockwise'],
    ['pitched up', aboutX(5), '0.0° right, 5.0° up, 0.0° clockwise'],
    ['pitched down', aboutX(-2), '0.0° right, 2.0° down, 0.0° clockwise'],
    ['rolled clockwise, seen from behind', aboutZ(7), '0.0° right, 0.0° up, 7.0° clockwise'],
    ['rolled anticlockwise', aboutZ(-6), '0.0° right, 0.0° up, 6.0° anticlockwise']
  ])('says a camera %s', (_case, orientation, words) => {
    expect(turnText(placed(orientation, [0, 0, 0]))).toBe(words)
  })

  it.each([
    [[0.1, 0.008, 0], '100.0 mm right, 8.0 mm down, 0.0 mm forward'],
    [[-0.05, -0.02, -0.01], '50.0 mm left, 20.0 mm up, 10.0 mm back']
  ])('says where a camera at %j m sits from the left camera', (position, words) => {
    expect(positionText(placed(aboutY(10), position))).toBe(words)
  })

  it('says nothing without a pose', () => {
    expect(positionText(null)).toBe('–')
    expect(turnText(null)).toBe('–')
  })
})
