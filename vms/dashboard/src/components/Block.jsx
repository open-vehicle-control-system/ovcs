import { Suspense, lazy } from 'react'
import { OvcsCard } from '@ovcs/ui/react'
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

/** A block in its card, under its name; a block of a subtype the dashboard does not render is left out. */
export default function Block({ block, refreshInterval }) {
  if (!SUBTYPES.has(block.subtype)) return null

  return (
    <OvcsCard className={`flex min-w-0 flex-col gap-3 ${block.fullWidth ? 'lg:col-span-3' : ''}`}>
      <h3 className="font-semibold">{block.name}</h3>
      <Content block={block} refreshInterval={refreshInterval} />
    </OvcsCard>
  )
}
