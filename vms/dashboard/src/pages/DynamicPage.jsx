import { useEffect, useState } from 'react'
import { OvcsPageFrame } from '@ovcs/ui/react'
import BlockGrid from '../components/BlockGrid.jsx'
import LiveContent from '../components/LiveContent.jsx'
import { pageMetrics } from '../blocks.js'
import { fetchBlocks } from '../services/api.js'
import { useMetrics } from '../stores/metrics.js'
import { useVehicle } from '../stores/vehicle.js'

function useBlocks(pageId) {
  const [state, setState] = useState({ blocks: null, error: null })

  useEffect(() => {
    let live = true
    fetchBlocks(pageId).then(
      (blocks) => {
        if (live) setState({ blocks, error: null })
      },
      (error) => {
        if (live) setState({ blocks: null, error: error.message })
      }
    )
    return () => {
      live = false
    }
  }, [pageId])

  return state
}

/** A page the vehicle declares: its blocks, whose metrics it watches while shown. */
export default function DynamicPage({ page }) {
  const { blocks, error } = useBlocks(page.id)
  const refreshInterval = useVehicle((state) => state.vehicle?.refreshInterval)
  const watch = useMetrics((state) => state.watch)

  useEffect(() => (blocks ? watch(pageMetrics(blocks)) : undefined), [blocks, watch])

  return (
    <OvcsPageFrame title={page.name}>
      {error ? (
        <p role="alert" className="ovcs-status ovcs-status--error text-sm text-ovcs-error-text">
          {error}
        </p>
      ) : blocks ? (
        <LiveContent>
          <BlockGrid blocks={blocks} refreshInterval={refreshInterval} />
        </LiveContent>
      ) : (
        <p className="text-sm text-ovcs-muted">Loading…</p>
      )}
    </OvcsPageFrame>
  )
}
