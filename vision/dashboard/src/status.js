import { HINTS } from './hints.js'

/**
 * What the dashboard shows of the status snapshot: `{ id, title, value, healthy, detail }` items, and
 * each preview's figures as `{ label, value, tone }`, `tone` set on the one that tells the stream's health.
 */

export const formatNumber = (number, decimals = 1) => (number == null ? '–' : Number(number).toFixed(decimals))

export function cameraFigures(camera) {
  if (!camera || !camera.present) return [{ label: 'camera', value: 'absent', tone: 'error', hint: HINTS.cameraRate }]
  const figures = [
    { label: 'rate', value: `${formatNumber(camera.fps)} fps`, tone: camera.fps > 0 ? 'ok' : 'error', hint: HINTS.cameraRate }
  ]
  if (camera.exposure_time_us != null) {
    figures.push({ label: 'exposure', value: `${formatNumber(camera.exposure_time_us / 1000)} ms`, hint: HINTS.exposure })
  }
  if (camera.analogue_gain != null) {
    figures.push({ label: 'gain', value: formatNumber(camera.analogue_gain), hint: HINTS.gain })
  }
  return figures
}

export function syncStatus(sync) {
  if (!sync || !sync.present) return { id: 'sync', title: 'Synchronisation', value: 'absent', healthy: false }
  if (sync.offset_median_ms == null) return { id: 'sync', title: 'Synchronisation', value: 'no pairs', healthy: false }
  return {
    id: 'sync',
    title: 'Synchronisation',
    value: `${formatNumber(sync.offset_median_ms, 2)} ms`,
    healthy: Math.abs(sync.offset_median_ms) <= 1,
    detail: `max ${formatNumber(sync.offset_max_ms, 2)} ms over ${sync.pairs} pairs`,
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
      value: `${formatNumber(quality.matched_percent, 0)} %`,
      hint: HINTS.matched
    },
    {
      label: 'disparity',
      value: `${formatNumber(quality.mean_disparity_px)} ± ${formatNumber(quality.spread_px)} px`,
      hint: HINTS.disparity
    },
    {
      label: 'jitter',
      value: `${formatNumber(quality.jitter_px, 2)} px`,
      hint: HINTS.jitter
    }
  ]
}

function loadStatus(id, title, percent, detail) {
  return {
    id,
    title,
    value: percent == null ? '–' : `${formatNumber(percent, 0)} %`,
    healthy: percent != null && percent < 90,
    detail
  }
}

// Rows the right image is offset by; past half a row the calibration no longer fits.
function alignmentStatus(alignment) {
  if (!alignment) return { id: 'alignment', title: 'Row alignment', value: '–', healthy: false }
  return {
    id: 'alignment',
    title: 'Row alignment',
    value: `${formatNumber(alignment.offset_rows)} rows`,
    healthy: Math.abs(alignment.offset_rows) <= 0.5,
    hint: HINTS.alignment,
    detail: `left to right ${alignment.band_offset_rows.map((rows) => formatNumber(rows)).join(' · ')}`
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

/** The unit's links and load. */
export function unitStatus(status) {
  return [
    { id: 'zenoh', title: 'Zenoh', value: status.zenoh, healthy: status.zenoh === 'connected', hint: HINTS.zenoh },
    { id: 'hailo', title: 'Hailo', value: status.hailo, healthy: status.hailo === 'running', hint: HINTS.hailo },
    { ...loadStatus('cpu', 'CPU', status.cpu_percent), hint: HINTS.cpu },
    { ...loadStatus('segment', 'GPU', status.stereo_segment_percent), hint: HINTS.gpu }
  ]
}
