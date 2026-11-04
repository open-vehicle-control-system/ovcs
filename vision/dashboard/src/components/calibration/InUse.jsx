import { OvcsBadge } from '@ovcs/ui/react'
import Section from './Section.jsx'
import { useCalibration } from '../../stores/calibration.js'
import { downloadYaml } from '../../services/calibration.js'
import { formatNumber, millimetres } from '../../status.js'
import { BUTTON } from '../../styles.js'

const SOURCES = { builtIn: 'Built-in', stored: 'Stored on the unit', none: 'None' }

const CONFIRM_RESET = 'Return to the built-in calibration? The calibration stored on the unit is deleted.'

const stamp = (iso) => new Intl.DateTimeFormat(undefined, { dateStyle: 'medium', timeStyle: 'short' }).format(new Date(iso))

function CameraRow({ name, camera }) {
  const distortion = camera.distortion ? camera.distortion.map((coefficient) => formatNumber(coefficient, 4)).join(', ') : '–'

  return (
    <tr className="border-t border-ovcs-border">
      <th scope="row" className="py-1 pr-3 font-medium capitalize">
        {name}
      </th>
      <td className="py-1 pr-3 text-right">{formatNumber(camera.fx)}</td>
      <td className="py-1 pr-3 text-right">{formatNumber(camera.fy)}</td>
      <td className="py-1 pr-3 text-right">{formatNumber(camera.cx)}</td>
      <td className="py-1 pr-3 text-right">{formatNumber(camera.cy)}</td>
      <td className="py-1 font-mono text-xs">{distortion}</td>
    </tr>
  )
}

/** The calibration the cameras use: where it comes from, per camera its intrinsics, the baseline and image size. */
export default function InUse() {
  const inUse = useCalibration((state) => state.inUse)
  const busy = useCalibration((state) => state.busy)
  const applying = useCalibration((state) => state.session?.phase === 'applying')
  const reset = useCalibration((state) => state.reset)

  const download = () => {
    downloadYaml(`${inUse.prefix}_left.yaml`, inUse.left.yaml)
    downloadYaml(`${inUse.prefix}_right.yaml`, inUse.right.yaml)
  }

  const returnToBuiltIn = () => {
    if (window.confirm(CONFIRM_RESET)) reset()
  }

  return (
    <Section title="In use">
      {inUse ? (
        <>
          <p className="flex flex-wrap items-center gap-2 text-sm">
            <OvcsBadge tone={inUse.source === 'none' ? 'warn' : 'neutral'}>{SOURCES[inUse.source]}</OvcsBadge>
            {inUse.storedAt ? <span className="text-ovcs-muted">stored {stamp(inUse.storedAt)}</span> : null}
          </p>
          <div className="overflow-x-auto">
            <table className="w-full text-left text-sm tabular-nums">
              <thead className="text-xs text-ovcs-muted">
                <tr>
                  <th className="pb-1 pr-3 font-medium">camera</th>
                  <th className="pb-1 pr-3 text-right font-medium">fx</th>
                  <th className="pb-1 pr-3 text-right font-medium">fy</th>
                  <th className="pb-1 pr-3 text-right font-medium">cx</th>
                  <th className="pb-1 pr-3 text-right font-medium">cy</th>
                  <th className="pb-1 font-medium">distortion</th>
                </tr>
              </thead>
              <tbody>
                <CameraRow name="left" camera={inUse.left} />
                <CameraRow name="right" camera={inUse.right} />
              </tbody>
            </table>
          </div>
          <dl className="flex flex-wrap gap-x-6 gap-y-1 text-sm tabular-nums">
            <div className="flex gap-2">
              <dt className="text-ovcs-muted">baseline</dt>
              <dd>{millimetres(inUse.baselineM)}</dd>
            </div>
            <div className="flex gap-2">
              <dt className="text-ovcs-muted">image</dt>
              <dd>{inUse.left.imageWidth ? `${inUse.left.imageWidth} × ${inUse.left.imageHeight}` : '–'}</dd>
            </div>
          </dl>
          <div className="flex flex-wrap gap-2">
            {inUse.left.yaml && inUse.right.yaml ? (
              <button type="button" aria-label="Download the calibration in use" onClick={download} className={BUTTON}>
                Download
              </button>
            ) : null}
            {inUse.canReset ? (
              <button type="button" disabled={busy || applying} onClick={returnToBuiltIn} className={BUTTON}>
                Return to built-in
              </button>
            ) : null}
          </div>
        </>
      ) : (
        <p className="text-sm text-ovcs-muted">Waiting for the vision unit…</p>
      )}
    </Section>
  )
}
