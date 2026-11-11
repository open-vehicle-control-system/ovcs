import { HINTS } from './hints.js'
import { issueActions, issueWording } from './pairIssues.js'

/**
 * What the dashboard shows of the status snapshot: `{ id, title, value, healthy, tone, detail, hint }` items, `tone`
 * overriding the health colour, and each preview's figures as `{ label, value, tone, hint }`, `tone` set on the one
 * that tells the stream's health.
 */

export const formatNumber = (number, decimals = 1) => (number == null ? '–' : Number(number).toFixed(decimals))

export function cameraFigures(camera) {
  if (!camera || !camera.present) return [{ label: 'camera', value: 'absent', tone: 'error', hint: HINTS.cameraRate }]
  const figures = [
    { label: 'rate', value: `${formatNumber(camera.fps)} fps`, tone: camera.fps > 0 ? 'ok' : 'error', hint: HINTS.cameraRate }
  ]
  if (camera.exposureTimeUs != null) {
    figures.push({ label: 'exposure', value: `${formatNumber(camera.exposureTimeUs / 1000)} ms`, hint: HINTS.exposure })
  }
  if (camera.analogueGain != null) {
    figures.push({ label: 'gain', value: formatNumber(camera.analogueGain), hint: HINTS.gain })
  }
  return figures
}

/** How many objects the latest detection result holds, none without detection. */
export function objectFigures(detections) {
  return detections ? [{ label: 'objects', value: String(detections.length), hint: HINTS.objects }] : []
}

// After the rate, the quality stage's averages: pixels matched, disparity mean and spread, and jitter, the matcher's noise on a still scene.
export function depthFigures(hz, quality) {
  const figures = [{ label: 'rate', value: `${formatNumber(hz)} Hz`, tone: hz > 0 ? 'ok' : 'error', hint: HINTS.depthRate }]
  if (!quality) return figures
  return [
    ...figures,
    {
      label: 'matched',
      value: `${formatNumber(quality.matchedPercent, 0)} %`,
      hint: HINTS.matched
    },
    {
      label: 'disparity',
      value: `${formatNumber(quality.meanDisparityPx)} ± ${formatNumber(quality.spreadPx)} px`,
      hint: HINTS.disparity
    },
    {
      label: 'jitter',
      value: `${formatNumber(quality.jitterPx, 2)} px`,
      hint: HINTS.jitter
    }
  ]
}

function loadStatus(id, title, percent) {
  return {
    id,
    title,
    value: percent == null ? '–' : `${formatNumber(percent, 0)} %`,
    widest: '100 %',
    align: 'end',
    healthy: percent != null && percent < 90
  }
}

// A check of the unit's `pair`, as its item: a dash while it has nothing to judge, the unit's level as its health;
// `describe` gives the value, its short `detail` and the `more` figures of a check that has them.
function checkItem({ id, title, hint, widest }, check, describe) {
  const blank = { id, title, widest, hint, value: '–', detail: '', more: '', healthy: false, tone: 'muted', camera: null, issues: [] }
  if (!check || check.level === 'off') return blank
  const [value, detail, more] = describe(check)
  return {
    ...blank,
    value,
    detail,
    more,
    healthy: check.level === 'ok',
    tone: undefined,
    gauge: check.gauge,
    camera: check.camera,
    issues: check.issues.map(issueWording)
  }
}

export const PAIR_CHECKS = [
  { id: 'timing', title: 'Timing', hint: HINTS.timing, widest: '00.00 ms' },
  { id: 'rows', title: 'Rows', hint: HINTS.rows, widest: '00.0 rows' },
  { id: 'focus', title: 'Focus', hint: HINTS.focus, widest: '100 %' }
]

/** How the cameras work together, as the unit judges them (`pair`): their timing, rows and focus. */
export function pairStatus(status) {
  const { timing, rows, focus } = status.pair ?? {}
  const [timingCheck, rowsCheck, focusCheck] = PAIR_CHECKS

  return [
    checkItem(timingCheck, timing, (check) => [
      `${formatNumber(check.offsetMs, 2)} ms`,
      `${check.later} later · max ${formatNumber(check.maxOffsetMs, 2)}`,
      `over ${check.pairs} pairs`
    ]),
    checkItem(rowsCheck, rows, (check) => [
      `${formatNumber(check.misalignmentRows)} rows`,
      `right ${check.direction} · corrected ${formatNumber(check.correctionRows)}`,
      `left to right ${check.bandOffsetRows.map((band) => formatNumber(band)).join(' · ')}`
    ]),
    checkItem(focusCheck, focus, (check) => [
      `${check.differencePercent} %`,
      `${check.softer} softer`,
      `left ${formatNumber(check.left, 4)} · right ${formatNumber(check.right, 4)}`
    ])
  ]
}

/** What the unit found wrong with one camera: the `actions` it calls for and their full `wording`. */
export function cameraIssues(camera) {
  const issues = camera?.issues ?? []
  return { actions: issueActions(issues), wording: issues.map(issueWording) }
}

// The ROS 2 exporter's status, lower-cased like the other values; none on a unit without a ROS 2 exporter.
function ros2Status(exporters) {
  const ros2 = (exporters ?? []).find((exporter) => exporter.id === 'ros2')
  if (!ros2) return []
  const { level, detail } = ros2.status
  return [
    {
      id: 'ros2',
      title: 'ROS 2',
      value: detail.charAt(0).toLowerCase() + detail.slice(1),
      widest: 'not answering',
      healthy: level === 'ok',
      hint: HINTS.ros2
    }
  ]
}

/** The unit's links and load, each with the widest form of its value, which the top bar keeps room for. */
export function unitStatus(status) {
  return [
    ...ros2Status(status.exporters),
    // Absent is a unit built without an accelerator, not a fault.
    {
      id: 'hailo',
      title: 'Hailo',
      value: status.hailo,
      widest: 'running',
      healthy: status.hailo === 'running',
      tone: status.hailo === 'absent' ? 'muted' : undefined,
      hint: HINTS.hailo
    },
    { ...loadStatus('cpu', 'CPU', status.cpuPercent), hint: HINTS.cpu },
    { ...loadStatus('segment', 'Stereo load', status.stereoLoadPercent), hint: HINTS.stereoLoad }
  ]
}
