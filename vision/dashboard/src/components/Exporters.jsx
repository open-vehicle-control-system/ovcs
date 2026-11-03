import { useShallow } from 'zustand/react/shallow'
import { OvcsMenuItem, OvcsMenuList } from '@ovcs/ui/react'
import { STATUS_STYLES } from './menu.js'
import { exporterStatus, useExporters } from '../stores/exporters.js'
import { useNavigation } from '../stores/navigation.js'
import { useStatus } from '../stores/status.js'

/** The unit's exporters as the API lists them, each with its status like a pipeline's box, opening its page. */
export default function Exporters() {
  const exporters = useExporters((state) => state.exporters)
  // Each one's level and detail, flat, so a status that changes none of them does not render the menu again.
  const statuses = useStatus(
    useShallow((state) =>
      exporters.flatMap((exporter) => {
        const status = exporterStatus(exporter, state.snapshot)
        return [status?.level, status?.detail]
      })
    )
  )
  const selected = useNavigation((state) => (state.page === 'exporter' ? state.exporterId : null))
  const openExporter = useNavigation((state) => state.openExporter)

  return (
    <OvcsMenuList label="Exporters">
      {exporters.map((exporter, index) => {
        const [level, detail] = statuses.slice(2 * index, 2 * index + 2)
        const style = STATUS_STYLES[level] ?? STATUS_STYLES.ok
        return (
          <li key={exporter.id}>
            <OvcsMenuItem
              selected={selected === exporter.id}
              aria-label={level ? `${exporter.name}, ${level}: ${detail}` : exporter.name}
              title={detail}
              onClick={() => openExporter(exporter.id)}
              className={`border ${style.border}`}
            >
              <span translate="no">{exporter.name}</span>
              {style.dot ? <span aria-hidden="true" className={`ml-auto ${style.dot}`} /> : null}
            </OvcsMenuItem>
          </li>
        )
      })}
    </OvcsMenuList>
  )
}
