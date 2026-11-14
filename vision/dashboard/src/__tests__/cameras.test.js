import { describe, expect, it } from 'vitest'
import { cameraGroup, cameraStatus, unitCameras } from '../cameras.js'

const group = (id, pipeline, role, position = 0) => ({ id, name: id, pipeline, role, position, parameterIds: [] })

const STEREO_CAMERAS = group('stereo.cameras', 'stereo', 'source', 0)
const PAIRING = group('stereo.pairing', 'stereo', 'source', 0)
const MATCH = group('stereo.match', 'stereo', 'step', 2)
const CENTER_CAMERA = group('center.camera', 'center', 'source', 50)
const OBJECTS_INPUT = group('objects.input', 'objects', 'step', 101)

describe('cameraGroup', () => {
  it("names the camera whose own controls a group holds: the stereo pair's, or a camera of its own's", () => {
    expect(cameraGroup(STEREO_CAMERAS)).toBe('stereo')
    expect(cameraGroup(group('cameras', 'stereo', 'source'))).toBe('stereo')
    expect(cameraGroup(CENTER_CAMERA)).toBe('center')
  })

  it("names none for another component or a step, the pairing's included", () => {
    expect(cameraGroup(PAIRING)).toBeNull()
    expect(cameraGroup(MATCH)).toBeNull()
    expect(cameraGroup(OBJECTS_INPUT)).toBeNull()
    expect(cameraGroup(group('objects.camera', 'objects', 'step'))).toBeNull()
  })
})

describe('unitCameras', () => {
  it("lists the stereo pair first, then each camera of its own, each with its settings, calibration and position", () => {
    const targets = [
      { id: 'stereo', kind: 'stereo' },
      { id: 'center', kind: 'camera' },
      { id: 'center-pose', kind: 'pose' }
    ]

    expect(unitCameras([CENTER_CAMERA, MATCH, PAIRING, STEREO_CAMERAS], targets)).toEqual([
      { key: 'stereo', kind: 'stereo', name: 'Stereo cameras', settings: 'stereo.cameras', calibration: 'stereo', position: null },
      { key: 'center', kind: 'camera', name: 'Center camera', settings: 'center.camera', calibration: 'center', position: 'center-pose' }
    ])
  })

  it("finds the stereo pair's calibration by its kind, whatever the unit's prefix", () => {
    expect(unitCameras([], [{ id: 'front', kind: 'stereo' }])).toEqual([
      { key: 'stereo', kind: 'stereo', name: 'Stereo cameras', settings: null, calibration: 'front', position: null }
    ])
  })

  it('lists the stereo pair from its pipeline with its settings, before anything can be calibrated', () => {
    expect(unitCameras([MATCH, STEREO_CAMERAS], [])).toEqual([
      { key: 'stereo', kind: 'stereo', name: 'Stereo cameras', settings: 'stereo.cameras', calibration: null, position: null }
    ])
  })

  it('lists no camera with nothing to set, calibrate or measure', () => {
    expect(unitCameras([MATCH, PAIRING], [])).toEqual([])
  })

  it('lists a camera of its own from its group alone, or from its position alone', () => {
    expect(unitCameras([CENTER_CAMERA], [])).toEqual([
      { key: 'center', kind: 'camera', name: 'Center camera', settings: 'center.camera', calibration: null, position: null }
    ])
    expect(unitCameras([], [{ id: 'rear-pose', kind: 'pose' }])).toEqual([
      { key: 'rear', kind: 'camera', name: 'Rear camera', settings: null, calibration: null, position: 'rear-pose' }
    ])
  })

  it('lists no camera on a unit without any', () => {
    expect(unitCameras([OBJECTS_INPUT], [])).toEqual([])
  })
})

describe('cameraStatus', () => {
  const stereo = { key: 'stereo', kind: 'stereo' }
  const center = { key: 'center', kind: 'camera' }
  const present = (fps, issues = []) => ({ present: true, fps, issues })

  it('says nothing before the unit reports', () => {
    expect(cameraStatus(null, stereo)).toBeNull()
  })

  it("gives a camera of its own's rate, ok while it delivers frames", () => {
    const snapshot = { cameras: { left: present(10), right: present(10), center: present(29.97) } }
    expect(cameraStatus(snapshot, center)).toEqual({ level: 'ok', detail: null, fps: '30 fps' })
  })

  it("gives the stereo pair the lower of its sides' rates, and the worst of their states", () => {
    expect(cameraStatus({ cameras: { left: present(30), right: present(24.6) } }, stereo)).toEqual({
      level: 'ok',
      detail: null,
      fps: '25 fps'
    })
    expect(cameraStatus({ cameras: { left: present(30), right: present(30, ['focus_mismatch']) } }, stereo)).toEqual({
      level: 'warning',
      detail: 'Softer than the other camera: refocus it',
      fps: '30 fps'
    })
    expect(cameraStatus({ cameras: { left: present(30), right: { present: false } } }, stereo)).toEqual({
      level: 'error',
      detail: 'absent',
      fps: null
    })
  })

  it('is an error for a camera the unit does not report, or that delivers no frame', () => {
    expect(cameraStatus({ cameras: {} }, center)).toEqual({ level: 'error', detail: 'absent', fps: null })
    expect(cameraStatus({ cameras: { center: present(0) } }, center)).toEqual({ level: 'error', detail: 'no frames', fps: '0 fps' })
  })
})
