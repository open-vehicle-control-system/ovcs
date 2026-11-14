import { useEffect, useId, useRef, useState } from 'react'
import { OvcsBadge, focusClass as FOCUS } from '@ovcs/ui/react'
import Section from './Section.jsx'
import { selectedCalibration, selectedId, useCalibration } from '../../stores/calibration.js'
import { formatNumber, millimetres } from '../../status.js'
import { BUTTON } from '../../styles.js'

const ORIGINS = { dashboard: 'Made on this page', imported: 'Found on the unit' }

const stamp = (iso) => new Intl.DateTimeFormat(undefined, { dateStyle: 'medium', timeStyle: 'short' }).format(new Date(iso))

const NONE = []

// The reprojection errors of the solve that made a calibration, each camera's then the pair's; none for one found on the unit.
function errors({ cameras, stereoRmsPx }) {
  const each = cameras.filter((camera) => camera.rmsPx != null).map((camera) => `${camera.name} ${formatNumber(camera.rmsPx, 2)} px`)
  if (stereoRmsPx != null) each.push(`pair ${formatNumber(stereoRmsPx, 2)} px`)
  return each.length > 0 ? each.join(', ') : '–'
}

const CELL = 'border-t border-ovcs-border py-1.5 pr-4 align-middle'

function InUse() {
  return <OvcsBadge tone="ok">In use</OvcsBadge>
}

/** The firmware's calibration, which the unit goes back to: nothing kept is removed. */
function FirmwareRow({ inUse, busy, onUse }) {
  return (
    <tr>
      <th scope="row" className={`${CELL} font-medium`}>
        Shipped with the firmware
      </th>
      <td className={CELL} />
      <td className={CELL} />
      <td className={CELL} />
      <td className={`${CELL} pr-0`}>
        <div className="flex flex-wrap items-center justify-end gap-2">
          {inUse ? (
            <InUse />
          ) : (
            <button type="button" disabled={busy} aria-label="Use the calibration shipped with the firmware" onClick={onUse} className={BUTTON}>
              Use
            </button>
          )}
        </div>
      </td>
    </tr>
  )
}

/**
 * A kept calibration's name, renamed in place: the focus goes to the name's field when it opens, and once it closes
 * back to Rename, or to the name itself while the rename disables that button.
 */
function Name({ kept, busy }) {
  const inputId = useId()
  const rename = useCalibration((state) => state.renameSaved)
  const [draft, setDraft] = useState(null)
  const editing = draft !== null
  const wasEditing = useRef(false)
  const input = useRef(null)
  const name = useRef(null)
  const renameButton = useRef(null)

  useEffect(() => {
    if (editing) {
      input.current?.focus()
      input.current?.select()
    } else if (wasEditing.current) {
      const back = renameButton.current?.disabled ? name.current : renameButton.current
      back?.focus()
    }
    wasEditing.current = editing
  }, [editing])

  if (!editing)
    return (
      <span ref={name} tabIndex={-1} className={`flex flex-wrap items-center gap-2 rounded ${FOCUS}`}>
        {kept.name}
        <button ref={renameButton} type="button" disabled={busy} aria-label={`Rename ${kept.name}`} onClick={() => setDraft(kept.name)} className={`rounded text-xs text-ovcs-muted underline hover:text-ovcs-text ${FOCUS}`}>
          Rename
        </button>
      </span>
    )

  const submit = (event) => {
    event.preventDefault()
    const name = draft.trim()
    if (name === '') return
    if (name !== kept.name) rename(kept.id, name)
    setDraft(null)
  }

  return (
    <form onSubmit={submit} className="flex flex-wrap items-center gap-2">
      <label htmlFor={inputId} className="sr-only">{`Name of ${kept.name}`}</label>
      <input
        ref={input}
        id={inputId}
        value={draft}
        maxLength={80}
        required
        autoComplete="off"
        onChange={(event) => setDraft(event.target.value)}
        onKeyDown={(event) => {
          if (event.key === 'Escape') setDraft(null)
        }}
        className={`min-h-8 w-56 rounded border border-ovcs-border bg-ovcs-bg px-2 font-normal ${FOCUS}`}
      />
      <button type="submit" className={BUTTON}>
        Save
      </button>
      <button type="button" onClick={() => setDraft(null)} className={BUTTON}>
        Cancel
      </button>
    </form>
  )
}

function Row({ kept, pair, busy }) {
  const use = useCalibration((state) => state.useSaved)
  const remove = useCalibration((state) => state.deleteSaved)

  const confirmRemove = () => {
    if (window.confirm(`Delete the calibration "${kept.name}"?`)) remove(kept.id)
  }

  return (
    <tr>
      <th scope="row" className={`${CELL} font-medium`}>
        <Name kept={kept} busy={busy} />
      </th>
      <td className={`${CELL} text-ovcs-muted`}>
        {stamp(kept.createdAt)}
        <span className="block text-xs">{ORIGINS[kept.origin] ?? kept.origin}</span>
      </td>
      <td className={`${CELL} tabular-nums`}>{errors(kept)}</td>
      <td className={`${CELL} tabular-nums`}>{pair ? millimetres(kept.baselineM) : ''}</td>
      <td className={`${CELL} pr-0`}>
        <div className="flex flex-wrap items-center justify-end gap-2">
          {kept.inForce ? (
            <InUse />
          ) : (
            <>
              <button type="button" disabled={busy} aria-label={`Use ${kept.name}`} onClick={() => use(kept.id)} className={BUTTON}>
                Use
              </button>
              <button type="button" disabled={busy} aria-label={`Delete ${kept.name}`} onClick={confirmRemove} className={BUTTON}>
                Delete
              </button>
            </>
          )}
        </div>
      </td>
    </tr>
  )
}

/**
 * Every calibration the unit keeps for the one shown, the newest first, and the firmware's: each can be put back in
 * use, a kept one renamed, and one that is not in use deleted. Nothing changes while a calibration session runs.
 */
export default function Saved() {
  const calibration = useCalibration(selectedCalibration)
  const kept = useCalibration((state) => state.saved[selectedId(state)] ?? NONE)
  const busy = useCalibration((state) => state.busy || (state.session?.phase ?? 'idle') !== 'idle')
  const reset = useCalibration((state) => state.reset)

  if (!calibration) return null

  const pair = calibration.kind === 'stereo'
  const firmware = calibration.source === 'builtIn' || calibration.canReset

  return (
    <Section title="Calibrations kept on the unit">
      {kept.length === 0 && !firmware ? (
        <p className="text-sm text-ovcs-muted">None yet: each calibration made is kept here, to name and to use again.</p>
      ) : (
        <div className="overflow-x-auto">
          <table className="w-full text-left text-sm">
            <thead className="text-xs text-ovcs-muted">
              <tr>
                <th className="pb-1 pr-4 font-medium">Name</th>
                <th className="pb-1 pr-4 font-medium">Made</th>
                <th className="pb-1 pr-4 font-medium">Errors (reprojection RMS)</th>
                <th className="pb-1 pr-4 font-medium">{pair ? 'Distance between cameras (baseline)' : ''}</th>
                <th className="pb-1 font-medium">
                  <span className="sr-only">Actions</span>
                </th>
              </tr>
            </thead>
            <tbody>
              {kept.map((one) => (
                <Row key={one.id} kept={one} pair={pair} busy={busy} />
              ))}
              {firmware ? <FirmwareRow inUse={calibration.source === 'builtIn'} busy={busy} onUse={reset} /> : null}
            </tbody>
          </table>
        </div>
      )}
    </Section>
  )
}
