import { poseCamera } from './services/calibration.js'
import { cameraIssues } from './status.js'

/** The stereo pair's key among the cameras: the name of its pipeline. */
export const STEREO = 'stereo'

// The unit status reports the stereo pair's cameras by their side.
const STEREO_SIDES = ['left', 'right']

const lastSegment = (id) => id.slice(id.lastIndexOf('.') + 1)

// `center` reads as "Center camera".
const cameraName = (key, kind) => (kind === 'stereo' ? 'Stereo cameras' : `${key.charAt(0).toUpperCase()}${key.slice(1)} camera`)

/**
 * The camera whose capture settings `group` holds: `stereo` for the stereo pair's (`<prefix>.cameras`), the name of a
 * camera of its own for its `<name>.camera`, else `null`.
 */
export function cameraGroup(group) {
  if (group.role !== 'source') return null
  if (group.pipeline === STEREO && lastSegment(group.id) === 'cameras') return STEREO
  return group.id === `${group.pipeline}.camera` ? group.pipeline : null
}

/**
 * The unit's cameras, the stereo pair first, as `{ key, kind, name, settings, calibration, position }`: the ids of the
 * group of its settings and of its calibration and position targets, `null` for what it does not have. The stereo pair
 * is listed on a unit with a stereo pipeline or calibration, a camera of its own when any of the three names it, and
 * neither without any of the three.
 */
export function unitCameras(groups, targets) {
  const cameras = new Map()
  const camera = (key, kind) => {
    if (!cameras.has(key)) {
      cameras.set(key, { key, kind, name: cameraName(key, kind), settings: null, calibration: null, position: null })
    }
    return cameras.get(key)
  }

  if (targets.some((target) => target.kind === 'stereo') || groups.some((group) => group.pipeline === STEREO)) {
    camera(STEREO, 'stereo')
  }
  for (const target of targets) {
    if (target.kind === 'stereo') camera(STEREO, 'stereo').calibration = target.id
    if (target.kind === 'camera') camera(target.id, 'camera').calibration = target.id
    if (target.kind === 'pose') camera(poseCamera(target.id), 'camera').position = target.id
  }
  for (const group of groups.toSorted((a, b) => a.position - b.position)) {
    const key = cameraGroup(group)
    if (key != null) camera(key, key === STEREO ? 'stereo' : 'camera').settings = group.id
  }
  return [...cameras.values()].filter((camera) => camera.settings ?? camera.calibration ?? camera.position)
}

const LEVELS = ['ok', 'warning', 'error']

// One camera's report, as its `level`, the `detail` of what is wrong and its rate.
function reportStatus(report) {
  if (!report?.present) return { level: 'error', detail: 'absent', fps: null }
  if (!(report.fps > 0)) return { level: 'error', detail: 'no frames', fps: report.fps ?? 0 }
  const { wording } = cameraIssues(report)
  if (wording.length > 0) return { level: 'warning', detail: wording.join('; '), fps: report.fps }
  return { level: 'ok', detail: null, fps: report.fps }
}

/**
 * What the unit status says of `camera`: its `level` (`ok`, `warning` or `error`), the `detail` of what is wrong and its
 * rate as `fps`; `null` before the unit reports. The stereo pair is as bad as its worse side, at the lower rate.
 */
export function cameraStatus(snapshot, camera) {
  if (!snapshot) return null
  const sides = camera.kind === 'stereo' ? STEREO_SIDES : [camera.key]
  const statuses = sides.map((side) => reportStatus(snapshot.cameras?.[side]))
  const worst = statuses.reduce((worse, status) => (LEVELS.indexOf(status.level) > LEVELS.indexOf(worse.level) ? status : worse))
  const rates = statuses.map((status) => status.fps)
  const fps = rates.includes(null) ? null : Math.min(...rates)
  return { level: worst.level, detail: worst.detail, fps: fps == null ? null : `${Math.round(fps)} fps` }
}
