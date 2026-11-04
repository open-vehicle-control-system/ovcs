import { Suspense, lazy } from 'react'
import { OvcsCard } from '@ovcs/ui/react'
import BlockErrorBoundary from './BlockErrorBoundary.jsx'
import RealTimeTable from './RealTimeTable.jsx'

// ECharts is only downloaded by a page that has a chart.
const RealTimeLineChart = lazy(() => import('./RealTimeLineChart.jsx'))

const CHART_PLACEHOLDER = <div className="h-[400px] w-full" />

function Content({ block, refreshInterval }) {
  if (block.subtype === 'table') return <RealTimeTable block={block} />
  return (
    <Suspense fallback={CHART_PLACEHOLDER}>
      <RealTimeLineChart block={block} refreshInterval={refreshInterval} />
    </Suspense>
  )
}

const SUBTYPES = new Set(['table', 'lineChart'])

/** Whether the dashboard renders a block's subtype; the others are left out. */
export const isRendered = (block) => SUBTYPES.has(block.subtype)

/** A block in its card, under its name. */
export default function Block({ block, refreshInterval }) {
  return (
    <OvcsCard className="flex min-w-0 flex-col gap-3">
      <h3 className="font-semibold">{block.name}</h3>
      <BlockErrorBoundary>
        <Content block={block} refreshInterval={refreshInterval} />
      </BlockErrorBoundary>
    </OvcsCard>
  )
}
