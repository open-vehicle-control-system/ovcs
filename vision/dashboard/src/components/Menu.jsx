import { OvcsMenu, OvcsMenuItem, OvcsMenuList, OvcsMenuSection } from '@ovcs/ui/react'
import Pipelines from './Pipelines.jsx'
import Exporters from './Exporters.jsx'
import { useNavigation } from '../stores/navigation.js'

const MAIN_PAGES = [
  ['overview', 'Overview'],
  ['calibration', 'Calibration']
]

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
      <OvcsMenuSection title="Pipelines">
        <Pipelines />
      </OvcsMenuSection>
      <OvcsMenuSection title="Exporters">
        <Exporters />
      </OvcsMenuSection>
    </OvcsMenu>
  )
}
