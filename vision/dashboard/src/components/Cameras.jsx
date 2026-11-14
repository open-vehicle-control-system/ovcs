import { useMemo } from 'react'
import { useShallow } from 'zustand/react/shallow'
import { OvcsMenuItem, OvcsMenuList, OvcsMenuSection } from '@ovcs/ui/react'
import { useGroupBox } from './Pipelines.jsx'
import { cameraStatus, unitCameras } from '../cameras.js'
import { useCalibration } from '../stores/calibration.js'
import { useNavigation } from '../stores/navigation.js'
import { useParameters } from '../stores/parameters.js'
import { useStatus } from '../stores/status.js'

// What a camera's calibration covers, by the camera's kind.
const CALIBRATION_DESCRIPTIONS = { stereo: 'Both lenses and their position to each other', camera: 'Its lens' }
const POSITION_DESCRIPTION = 'Relative to the stereo pair'

const DOTS = { ok: 'ovcs-status ovcs-status--ok', warning: 'ovcs-status ovcs-status--warn', error: 'ovcs-status ovcs-status--error' }

// A short figure or state at the end of a row, as a step's time is.
const FIGURE = 'text-[10px] font-normal tabular-nums text-ovcs-muted'

// The rows without a status border keep a transparent one, so that every row's text lines up.
const ROW = 'border border-transparent'

// The targets' ids and kinds, as one string so that a load listing the same does not render the menu again.
const listed = (state) => state.targets.map((target) => `${target.id}:${target.kind}`).join(',')

const targetsOf = (listing) =>
  listing
    .split(',')
    .filter(Boolean)
    .map((entry) => {
      const [id, kind] = entry.split(':')
      return { id, kind }
    })

const NO_STATUS = []

/** The camera's name, opening its first entry, with its state as a dot and its rate at the end once the unit reports. */
function CameraHeading({ camera, onOpen }) {
  // Flat, so that a status leaving the camera's state and rate as they were does not render the menu again.
  const [level, detail, fps] = useStatus(
    useShallow((state) => {
      const status = cameraStatus(state.snapshot, camera)
      return status ? [status.level, status.detail, status.fps] : NO_STATUS
    })
  )
  const label = level ? [camera.name, detail ? `${level}: ${detail}` : level, fps].filter(Boolean).join(', ') : undefined

  return (
    <OvcsMenuItem aria-label={label} title={detail ?? undefined} onClick={onOpen} className={`${ROW} font-medium`}>
      <span translate="no" className="whitespace-nowrap">{camera.name}</span>
      {level ? (
        <span aria-hidden="true" className="ml-auto flex shrink-0 items-center gap-1.5">
          {fps ? (
            <span data-fps className={`whitespace-nowrap ${FIGURE}`}>
              {fps}
            </span>
          ) : null}
          <span className={DOTS[level]} />
        </span>
      ) : null}
    </OvcsMenuItem>
  )
}

/** A camera's position entry, saying at its end when the position is not measured, once the unit has pushed it. */
function PositionItem({ id, selected, onOpen }) {
  const unmeasured = useCalibration((state) => {
    const calibration = state.calibrations[id]
    return calibration != null && (calibration.source ?? 'none') === 'none'
  })

  return (
    <OvcsMenuItem
      selected={selected}
      aria-label={unmeasured ? 'Position, not measured' : undefined}
      title={POSITION_DESCRIPTION}
      onClick={onOpen}
      className={ROW}
    >
      Position
      {unmeasured ? (
        <span aria-hidden="true" data-state className={`ml-auto ${FIGURE}`}>
          not measured
        </span>
      ) : null}
    </OvcsMenuItem>
  )
}

/** A camera with its entries: its settings, its calibration and its position, each when it has one. */
function Camera({ camera, settings, box, openedCalibration }) {
  const openCalibration = useNavigation((state) => state.openCalibration)
  const go = useNavigation((state) => state.go)
  const select = useParameters((state) => state.select)
  const openSettings = () => {
    select(settings.id)
    go('pipeline')
  }
  const openFirst = () => (settings ? openSettings() : openCalibration(camera.calibration ?? camera.position))

  return (
    <li>
      <CameraHeading camera={camera} onOpen={openFirst} />
      <OvcsMenuList label={camera.name} className="mt-1 pl-4">
        {settings ? <li>{box(settings, [settings], 'Settings')}</li> : null}
        {camera.calibration ? (
          <li>
            <OvcsMenuItem
              selected={openedCalibration === camera.calibration}
              title={CALIBRATION_DESCRIPTIONS[camera.kind]}
              onClick={() => openCalibration(camera.calibration)}
              className={ROW}
            >
              Calibration
            </OvcsMenuItem>
          </li>
        ) : null}
        {camera.position ? (
          <li>
            <PositionItem
              id={camera.position}
              selected={openedCalibration === camera.position}
              onOpen={() => openCalibration(camera.position)}
            />
          </li>
        ) : null}
      </OvcsMenuList>
    </li>
  )
}

/** The unit's cameras, the stereo pair first, each with what can be set, calibrated and measured of it. */
export default function Cameras() {
  const groups = useParameters((state) => state.groups)
  const listing = useCalibration(listed)
  const cameras = useMemo(() => unitCameras(groups, targetsOf(listing)), [groups, listing])
  const openedCalibration = useNavigation((state) => (state.page === 'calibration' ? state.calibrationId : null))
  const { box } = useGroupBox()

  if (cameras.length === 0) return null

  return (
    <OvcsMenuSection title="Cameras">
      <OvcsMenuList label="Cameras" className="gap-2">
        {cameras.map((camera) => (
          <Camera
            key={camera.key}
            camera={camera}
            settings={groups.find((group) => group.id === camera.settings)}
            box={box}
            openedCalibration={openedCalibration}
          />
        ))}
      </OvcsMenuList>
    </OvcsMenuSection>
  )
}
