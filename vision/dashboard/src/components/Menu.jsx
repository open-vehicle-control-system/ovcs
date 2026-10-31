import { useId } from 'react'
import { focusClass as FOCUS } from '@ovcs/ui/react'
import PipelineDiagram from './PipelineDiagram.jsx'
import { SECTION_HEADING, SELECTED } from './menu.js'
import { useNavigation } from '../stores/navigation.js'

const MAIN_PAGES = [
  ['overview', 'Overview'],
  ['calibration', 'Calibration']
]

const EXPORTER_PAGES = [
  ['ros2', 'ROS 2'],
  ['api', 'API']
]

function Section({ title, children }) {
  const id = useId()
  return (
    <section aria-labelledby={id} className="flex flex-col gap-1.5">
      <h2 id={id} className={SECTION_HEADING}>
        {title}
      </h2>
      {children}
    </section>
  )
}

function Pages({ label, pages }) {
  const page = useNavigation((state) => state.page)
  const go = useNavigation((state) => state.go)

  return (
    <ul aria-label={label} className="flex flex-col gap-1">
      {pages.map(([id, name]) => (
        <li key={id}>
          <button
            type="button"
            aria-current={page === id ? 'page' : undefined}
            onClick={() => go(id)}
            className={`flex min-h-9 w-full items-center rounded px-3 text-left text-sm ${
              page === id ? `${SELECTED} font-medium` : 'hover:bg-ovcs-bg'
            } ${FOCUS}`}
          >
            {name}
          </button>
        </li>
      ))}
    </ul>
  )
}

/** The unit's navigation: its own pages, the pipeline's stages, and what leaves the unit. */
export default function Menu() {
  return (
    <nav
      aria-label="Vision unit"
      className="flex shrink-0 flex-col gap-5 border-b border-ovcs-border bg-ovcs-surface px-3 py-4 lg:w-56 lg:overflow-y-auto lg:border-b-0 lg:border-r"
    >
      <Section title="Main">
        <Pages label="Main" pages={MAIN_PAGES} />
      </Section>
      <Section title="Pipeline">
        <PipelineDiagram />
      </Section>
      <Section title="Exporters">
        <Pages label="Exporters" pages={EXPORTER_PAGES} />
      </Section>
    </nav>
  )
}
