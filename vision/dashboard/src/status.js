import { HINTS } from './hints.js'

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

export function syncStatus(sync) {
  if (!sync || !sync.present) return { id: 'sync', title: 'Synchronisation', value: 'absent', healthy: false }
  if (sync.offsetMedianMs == null) return { id: 'sync', title: 'Synchronisation', value: 'no pairs', healthy: false }
  return {
    id: 'sync',
    title: 'Synchronisation',
    value: `${formatNumber(sync.offsetMedianMs, 2)} ms`,
    healthy: Math.abs(sync.offsetMedianMs) <= 1,
    detail: `max ${formatNumber(sync.offsetMaxMs, 2)} ms over ${sync.pairs} pairs`,
    hint: HINTS.sync
  }
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

// Rows the right image is offset by; past half a row the calibration no longer fits.
function alignmentStatus(alignment) {
  if (!alignment) return { id: 'alignment', title: 'Row alignment', value: '–', healthy: false }
  return {
    id: 'alignment',
    title: 'Row alignment',
    value: `${formatNumber(alignment.offsetRows)} rows`,
    healthy: Math.abs(alignment.offsetRows) <= 0.5,
    hint: HINTS.alignment,
    detail: `left to right ${alignment.bandOffsetRows.map((rows) => formatNumber(rows)).join(' · ')}`
  }
}

// The right camera's sharpness over the left's; far from 1, their focus differs.
function sharpnessStatus(sharpness) {
  if (!sharpness || !sharpness.left) return { id: 'sharpness', title: 'Sharpness, right / left', value: '–', healthy: false }
  const ratio = sharpness.right / sharpness.left
  return {
    id: 'sharpness',
    title: 'Sharpness, right / left',
    value: formatNumber(ratio, 2),
    healthy: ratio >= 0.8 && ratio <= 1.25,
    hint: HINTS.sharpness,
    detail: `left ${formatNumber(sharpness.left, 4)} · right ${formatNumber(sharpness.right, 4)}`
  }
}

/** How the two cameras compare: their sync, row alignment and sharpness. */
export function pairStatus(status) {
  return [syncStatus(status.sync), alignmentStatus(status.alignment), sharpnessStatus(status.sharpness)]
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
