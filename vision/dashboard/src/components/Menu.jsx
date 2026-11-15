import { OvcsMenu, OvcsMenuItem, OvcsMenuList, OvcsMenuSection } from '@ovcs/ui/react'
import Cameras from './Cameras.jsx'
import Pipelines from './Pipelines.jsx'
import Exporters from './Exporters.jsx'
import { useExporters } from '../stores/exporters.js'
import { useNavigation } from '../stores/navigation.js'
import { useParameters } from '../stores/parameters.js'

const MAIN_PAGES = [['overview', 'Overview']]

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

/**
 * The unit's navigation: its own pages, its cameras, the steps of its pipelines, and what leaves the unit, each
 * section once the unit has listed what it holds.
 */
export default function Menu() {
  const pipelinesListed = useParameters((state) => state.groups.length > 0)
  const exportersListed = useExporters((state) => state.exporters.length > 0)

  return (
    <OvcsMenu label="Vision unit">
      <OvcsMenuSection title="Main">
        <Pages label="Main" pages={MAIN_PAGES} />
      </OvcsMenuSection>
      <Cameras />
      {pipelinesListed ? (
        <OvcsMenuSection title="Pipelines">
          <Pipelines />
        </OvcsMenuSection>
      ) : null}
      {exportersListed ? (
        <OvcsMenuSection title="Exporters">
          <Exporters />
        </OvcsMenuSection>
      ) : null}
    </OvcsMenu>
  )
}
