import { selectedId, useCalibration } from '../../stores/calibration.js'
import { BUTTON, PRIMARY } from '../../styles.js'

const label = (calibration) => (calibration.kind === 'stereo' ? 'Stereo pair' : `Camera ${calibration.id}`)

// The ids and kinds, as one string so that a push changing none does not render again.
const listed = (state) => Object.values(state.calibrations).map((calibration) => `${calibration.id}:${calibration.kind}`).join(',')

/**
 * What to calibrate, on a unit with more than one calibration: its stereo pair or one of its cameras. The pick is
 * held while a session runs, which works on one of them.
 */
export default function Targets() {
  const calibrations = useCalibration(listed)
    .split(',')
    .filter(Boolean)
    .map((entry) => {
      const [id, kind] = entry.split(':')
      return { id, kind }
    })
  const selected = useCalibration(selectedId)
  const idle = useCalibration((state) => (state.session?.phase ?? 'idle') === 'idle')
  const select = useCalibration((state) => state.select)

  if (calibrations.length < 2) return null

  return (
    <div role="group" aria-label="Calibrate" className="flex flex-wrap gap-2">
      {calibrations.map((calibration) => (
        <button
          key={calibration.id}
          type="button"
          aria-pressed={calibration.id === selected}
          disabled={!idle}
          onClick={() => select(calibration.id)}
          className={calibration.id === selected ? PRIMARY : BUTTON}
        >
          {label(calibration)}
        </button>
      ))}
    </div>
  )
}
