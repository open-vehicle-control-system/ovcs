import { OvcsMenu, OvcsMenuItem, OvcsMenuList, OvcsMenuSection } from '@ovcs/ui/react'
import { NETWORK, pathOf, routeOf, useNavigation } from '../stores/navigation.js'

function Entries({ label, entries, pages }) {
  const path = useNavigation((state) => state.path)
  const go = useNavigation((state) => state.go)
  const current = routeOf(path, pages)

  return (
    <OvcsMenuList label={label}>
      {entries.map(({ id, name }) => (
        <li key={id}>
          <OvcsMenuItem selected={current === id} onClick={() => go(pathOf(id, pages))}>
            {name}
          </OvcsMenuItem>
        </li>
      ))}
    </OvcsMenuList>
  )
}

const SYSTEM = [{ id: NETWORK, name: 'Network' }]

/** The vehicle's pages, then the dashboard's own. */
export default function Menu({ pages }) {
  return (
    <OvcsMenu label="VMS">
      <OvcsMenuSection title="Pages">
        <Entries label="Pages" entries={pages} pages={pages} />
      </OvcsMenuSection>
      <OvcsMenuSection title="System">
        <Entries label="System" entries={SYSTEM} pages={pages} />
      </OvcsMenuSection>
    </OvcsMenu>
  )
}
