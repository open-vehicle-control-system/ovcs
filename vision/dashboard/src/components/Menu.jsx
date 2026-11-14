import { OvcsMenu, OvcsMenuItem, OvcsMenuList, OvcsMenuSection } from '@ovcs/ui/react'
import Pipelines from './Pipelines.jsx'
import Exporters from './Exporters.jsx'
import { useNavigation } from '../stores/navigation.js'
import { useCalibration } from '../stores/calibration.js'
import { calibrationName, poseId } from '../services/calibration.js'

const MAIN_PAGES = [['overview', 'Overview']]

// The ids and kinds, as one string so that a load listing the same does not render the menu again.
const listed = (state) => state.targets.map((target) => `${target.id}:${target.kind}`).join(',')

/** What the unit can calibrate, its stereo cameras first, each opening its calibration; a camera's position under its camera. */
function Calibrations() {
  const targets = useCalibration(listed)
    .split(',')
    .filter(Boolean)
    .map((entry) => {
      const [id, kind] = entry.split(':')
      return { id, kind }
    })
  const selected = useNavigation((state) => (state.page === 'calibration' ? state.calibrationId : null))
  const openCalibration = useNavigation((state) => state.openCalibration)

  if (targets.length === 0) return null

  const item = (target, label) => (
    <OvcsMenuItem selected={selected === target.id} onClick={() => openCalibration(target.id)}>
      {label}
    </OvcsMenuItem>
  )
  // A camera's position is listed under its camera.
  const positionOf = (target) => targets.find((other) => other.kind === 'pose' && other.id === poseId(target.id))

  return (
    <OvcsMenuSection title="Calibration">
      <OvcsMenuList label="Calibration">
        {targets
          .filter((target) => target.kind !== 'pose' || !targets.some((camera) => poseId(camera.id) === target.id))
          .map((target) => {
            const position = positionOf(target)

            return (
              <li key={target.id}>
                {item(target, calibrationName(target))}
                {position ? (
                  <OvcsMenuList label={calibrationName(target)} className="mt-1 pl-4">
                    <li>{item(position, 'Position')}</li>
                  </OvcsMenuList>
                ) : null}
              </li>
            )
          })}
      </OvcsMenuList>
    </OvcsMenuSection>
  )
}

function Pages({ label, pages }) {
  const page = useNavigation((state) => state.page)
  const go = useNavigation((state) => state.go)

  return (
    <OvcsMenuList label={label}>
      {pages.map(([id, name]) => (
        <li key={id}>
          <OvcsMenuItem selected={page === id} onClick={() => go(id)}>
            {name}
          </OvcsMenuItem>
        </li>
      ))}
    </OvcsMenuList>
  )
}

/** The unit's navigation: its own pages, the steps of its pipelines, and what leaves the unit. */
export default function Menu() {
  return (
    <OvcsMenu label="Vision unit">
      <OvcsMenuSection title="Main">
        <Pages label="Main" pages={MAIN_PAGES} />
      </OvcsMenuSection>
      <Calibrations />
      <OvcsMenuSection title="Pipelines">
        <Pipelines />
      </OvcsMenuSection>
      <OvcsMenuSection title="Exporters">
        <Exporters />
      </OvcsMenuSection>
    </OvcsMenu>
  )
}
