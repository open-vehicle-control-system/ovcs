const formatNumber = (number, decimals = 1) => (number == null ? '–' : Number(number).toFixed(decimals))

function cameraCard(id, title, camera) {
  if (!camera || !camera.present) {
    return { id, title, value: 'absent', healthy: false }
  }
  const details = []
  if (camera.exposure_time_us != null) details.push(`exposure ${formatNumber(camera.exposure_time_us / 1000, 2)} ms`)
  if (camera.analogue_gain != null) details.push(`gain ${formatNumber(camera.analogue_gain, 2)}`)
  return { id, title, value: `${formatNumber(camera.fps)} fps`, healthy: camera.fps > 0, detail: details.join(', ') }
}

function syncCard(sync) {
  if (!sync || !sync.present) return { id: 'sync', title: 'Sync', value: 'absent', healthy: false }
  if (sync.offset_median_ms == null) return { id: 'sync', title: 'Sync', value: 'no pairs', healthy: false }
  return {
    id: 'sync',
    title: 'Sync',
    value: `${formatNumber(sync.offset_median_ms, 2)} ms`,
    healthy: Math.abs(sync.offset_median_ms) <= 1,
    detail: `max ${formatNumber(sync.offset_max_ms, 2)} ms over ${sync.pairs} pairs`
  }
}

function loadCard(id, title, percent, detail) {
  return {
    id,
    title,
    value: percent == null ? '–' : `${formatNumber(percent, 0)} %`,
    healthy: percent != null && percent < 90,
    detail
  }
}

// Rows the right image is offset by; past half a row the calibration no longer fits.
function alignmentCard(alignment) {
  if (!alignment) return { id: 'alignment', title: 'Row alignment', value: '–', healthy: false }
  return {
    id: 'alignment',
    title: 'Row alignment',
    value: `${formatNumber(alignment.offset_rows)} rows`,
    healthy: Math.abs(alignment.offset_rows) <= 0.5,
    detail: `left to right: ${alignment.band_offset_rows.map((rows) => formatNumber(rows)).join(' · ')}`
  }
}

// The right camera's sharpness over the left's; far from 1, their focus differs.
function sharpnessCard(sharpness) {
  if (!sharpness || !sharpness.left) return { id: 'sharpness', title: 'Sharpness, right / left', value: '–', healthy: false }
  const ratio = sharpness.right / sharpness.left
  return {
    id: 'sharpness',
    title: 'Sharpness, right / left',
    value: formatNumber(ratio, 2),
    healthy: ratio >= 0.8 && ratio <= 1.25,
    detail: `left ${formatNumber(sharpness.left, 4)} · right ${formatNumber(sharpness.right, 4)}`
  }
}

function buildCards(status) {
  return [
    cameraCard('left', 'Left camera', status.cameras?.left),
    cameraCard('right', 'Right camera', status.cameras?.right),
    syncCard(status.sync),
    { id: 'depth', title: 'Depth', value: `${formatNumber(status.depth_hz)} Hz`, healthy: status.depth_hz > 0 },
    { id: 'hailo', title: 'Hailo', value: status.hailo, healthy: status.hailo === 'running' },
    { id: 'zenoh', title: 'Zenoh', value: status.zenoh, healthy: status.zenoh === 'connected' },
    loadCard('cpu', 'CPU', status.cpu_percent, 'all cores'),
    loadCard('segment', 'Stereo segment time', status.stereo_segment_percent, 'of each frame, GPU transfers included'),
    alignmentCard(status.alignment),
    sharpnessCard(status.sharpness)
  ]
}

export default function StatusCards({ status }) {
  if (!status) return <p className="text-sm text-ovcs-muted">Waiting for the vision unit…</p>

  return (
    <div className="grid grid-cols-2 gap-4 lg:grid-cols-4">
      {buildCards(status).map((card) => (
        <div key={card.id} data-card={card.id} className="ovcs-card">
          <p className="text-sm font-medium text-ovcs-muted">{card.title}</p>
          <p className={`ovcs-status ${card.healthy ? 'ovcs-status--ok' : 'ovcs-status--error'} mt-1 text-xl font-semibold tabular-nums`}>
            {card.value}
          </p>
          {card.detail && <p className="mt-1 text-xs text-ovcs-muted tabular-nums">{card.detail}</p>}
        </div>
      ))}
    </div>
  )
}
