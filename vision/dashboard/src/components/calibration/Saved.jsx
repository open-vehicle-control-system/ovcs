import { useEffect, useId, useRef, useState } from 'react'
import { OvcsBadge, focusClass as FOCUS, useOvcsConfirm } from '@ovcs/ui/react'
import Section from './Section.jsx'
import { BASELINE, Figures } from './Figures.jsx'
import { downloadFiles, yamlFiles } from './files.js'
import { distanceText } from './pose.js'
import Hint from '../Hint.jsx'
import { selectedCalibration, selectedId, useCalibration } from '../../stores/calibration.js'
import { formatNumber, millimetres } from '../../status.js'
import { SMALL_BUTTON } from '../../styles.js'

const ORIGINS = { dashboard: 'on this page', imported: 'outside this page' }

const ORIGIN_HINT = {
  title: 'Where it was made',
  text:
    'Made on this page: calibrated from this dashboard, with its board, views and errors. Made outside this page: ' +
    "committed by ROS 2's cameracalibrator, or stored on the unit before it kept its calibrations."
}

const stamp = (iso) => new Intl.DateTimeFormat(undefined, { dateStyle: 'medium', timeStyle: 'short' }).format(new Date(iso))

const NONE = []

// The reprojection errors of the solve that made a calibration, each camera's, named in a pair, then the pair's, or a position's; none for one made outside this page.
function errors({ cameras, stereoRmsPx, pose }) {
  if (pose) return pose.rmsPx == null ? [] : [`${formatNumber(pose.rmsPx, 2)} px`]
  const named = cameras.length > 1
  const each = cameras
    .filter((camera) => camera.rmsPx != null)
    .map((camera) => `${named ? `${camera.name} ` : ''}${formatNumber(camera.rmsPx, 2)} px`)
  if (stereoRmsPx != null) each.push(`pair ${formatNumber(stereoRmsPx, 2)} px`)
  return each
}

// The figures a calibration kept has: its reprojection errors, then a pair's baseline or a position's distance.
function figures(kept, kind) {
  const solved = errors(kept)
  return [
    ...(solved.length > 0 ? [{ label: 'Reprojection error', value: solved }] : []),
    ...(kind === 'stereo' && kept.baselineM != null ? [{ label: BASELINE, value: millimetres(kept.baselineM) }] : []),
    ...(kind === 'pose' && kept.pose?.distanceMm != null ? [{ label: 'Distance to the left camera', value: distanceText(kept.pose) }] : [])
  ]
}

const ITEM = 'flex flex-col gap-1.5 py-3 first:pt-0 last:pb-0'
const TITLE = 'flex flex-wrap items-center justify-between gap-x-2 gap-y-1'
const ACTIONS = 'flex flex-wrap items-center gap-1.5 pt-0.5'

function InUseBadge() {
  return <OvcsBadge tone="ok">In use</OvcsBadge>
}

/** The firmware's calibration or position, which the unit goes back to: nothing kept is removed. */
function FirmwareItem({ kind, inUse, busy, onUse }) {
  return (
    <li aria-label="Shipped with the firmware" className={ITEM}>
      <div className={TITLE}>
        <span className="font-medium">Shipped with the firmware</span>
        {inUse ? <InUseBadge /> : null}
      </div>
      <p className="text-xs text-ovcs-muted">
        {kind === 'pose' ? 'The position the firmware was built with' : 'The calibration the firmware was built with'}
      </p>
      {inUse ? null : (
        <div className={ACTIONS}>
          <button type="button" disabled={busy} aria-label="Use the calibration shipped with the firmware" onClick={onUse} className={SMALL_BUTTON}>
            Use
          </button>
        </div>
      )}
    </li>
  )
}

/** A field that renames a kept calibration, focused and selected when it opens; `onClose` ends it. */
function NameEditor({ kept, onClose }) {
  const inputId = useId()
  const rename = useCalibration((state) => state.renameSaved)
  const [draft, setDraft] = useState(kept.name)
  const input = useRef(null)

  useEffect(() => {
    input.current?.focus()
    input.current?.select()
  }, [])

  const submit = (event) => {
    event.preventDefault()
    const name = draft.trim()
    if (name === '') return
    if (name !== kept.name) rename(kept.id, name)
    onClose()
  }

  return (
    <form onSubmit={submit} className="flex items-center gap-1.5">
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
          if (event.key === 'Escape') onClose()
        }}
        className={`min-h-7 min-w-0 flex-1 rounded border border-ovcs-border bg-ovcs-bg px-2 text-sm ${FOCUS}`}
      />
      <button type="submit" className={SMALL_BUTTON}>
        Save
      </button>
      <button type="button" onClick={onClose} className={SMALL_BUTTON}>
        Cancel
      </button>
    </form>
  )
}

// Removing the calibration in use first takes the unit back to the firmware's.
const deleteQuestion = ({ name, inForce }) => ({
  title: `Delete the calibration "${name}"?`,
  message: inForce ? 'The unit uses it: it goes back to the calibration shipped with the firmware first.' : null,
  confirmLabel: 'Delete',
  danger: true
})

const NO_FIRMWARE = 'The unit has no calibration shipped with the firmware to go back to'

/**
 * A kept calibration; the one in use can be deleted only where `firmware`, the firmware's calibration, exists. Its name
 * gives way to a field while it is renamed; once renamed, the focus goes back to Rename, or to the name while the
 * rename disables that button.
 */
function Item({ kept, kind, busy, firmware }) {
  const noWayBack = kept.inForce && !firmware
  const use = useCalibration((state) => state.useSaved)
  const remove = useCalibration((state) => state.deleteSaved)
  const [confirm, confirmation] = useOvcsConfirm()
  const [renaming, setRenaming] = useState(false)
  const wasRenaming = useRef(false)
  const name = useRef(null)
  const renameButton = useRef(null)

  useEffect(() => {
    if (!renaming && wasRenaming.current) {
      const back = renameButton.current?.disabled ? name.current : renameButton.current
      back?.focus()
    }
    wasRenaming.current = renaming
  }, [renaming])

  const confirmRemove = async () => {
    if (await confirm(deleteQuestion(kept))) remove(kept.id)
  }

  const files = yamlFiles(kept, kept.pose != null)
  const shown = figures(kept, kind)

  return (
    <li aria-label={kept.name} className={ITEM}>
      {renaming ? (
        <NameEditor kept={kept} onClose={() => setRenaming(false)} />
      ) : (
        <div className={TITLE}>
          <span ref={name} tabIndex={-1} className={`min-w-0 break-words rounded font-medium ${FOCUS}`}>
            {kept.name}
          </span>
          {kept.inForce ? <InUseBadge /> : null}
        </div>
      )}
      <p className="text-xs text-ovcs-muted">{`Made ${stamp(kept.createdAt)} · ${ORIGINS[kept.origin] ?? kept.origin}`}</p>
      {shown.length > 0 ? <Figures figures={shown} /> : null}
      {renaming ? null : (
        <div className={ACTIONS}>
          {kept.inForce ? null : (
            <button type="button" disabled={busy} aria-label={`Use ${kept.name}`} onClick={() => use(kept.id)} className={SMALL_BUTTON}>
              Use
            </button>
          )}
          {files.length > 0 ? (
            <button type="button" aria-label={`Download ${kept.name}`} onClick={() => downloadFiles(files)} className={SMALL_BUTTON}>
              Download
            </button>
          ) : null}
          <button
            ref={renameButton}
            type="button"
            disabled={busy}
            aria-label={`Rename ${kept.name}`}
            onClick={() => setRenaming(true)}
            className={SMALL_BUTTON}
          >
            Rename
          </button>
          <button
            type="button"
            disabled={busy || noWayBack}
            title={noWayBack ? NO_FIRMWARE : undefined}
            aria-label={`Delete ${kept.name}`}
            onClick={confirmRemove}
            className={SMALL_BUTTON}
          >
            Delete
          </button>
          {confirmation}
        </div>
      )}
    </li>
  )
}

/**
 * Every calibration the unit keeps for the one shown, the newest first, and the firmware's: each can be put back in
 * use, and a kept one renamed, downloaded and deleted. Nothing changes while a calibration session runs.
 */
export default function Saved() {
  const calibration = useCalibration(selectedCalibration)
  const kept = useCalibration((state) => state.saved[selectedId(state)] ?? NONE)
  const busy = useCalibration((state) => state.busy || (state.session?.phase ?? 'idle') !== 'idle')
  const reset = useCalibration((state) => state.reset)

  if (!calibration) return null

  const firmware = calibration.source === 'builtIn' || calibration.canReset

  return (
    <Section title="Calibrations kept on the unit" hint={<Hint hint={ORIGIN_HINT} />} className="border-t border-ovcs-border pt-4">
      {kept.length === 0 && !firmware ? (
        <p className="text-sm text-ovcs-muted">None yet: each calibration made is kept here, to name and to use again.</p>
      ) : (
        <ul className="flex flex-col divide-y divide-ovcs-border text-sm">
          {kept.map((one) => (
            <Item key={one.id} kept={one} kind={calibration.kind} busy={busy} firmware={firmware} />
          ))}
          {firmware ? <FirmwareItem kind={calibration.kind} inUse={calibration.source === 'builtIn'} busy={busy} onUse={reset} /> : null}
        </ul>
      )}
    </Section>
  )
}
