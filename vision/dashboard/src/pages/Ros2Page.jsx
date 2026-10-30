import { useEffect, useState } from 'react'
import { OvcsCard, OvcsStatus } from '@ovcs/ui/react'
import PageFrame from './PageFrame.jsx'
import { fetchRos2Node } from '../services/unit.js'
import { formatNumber } from '../status.js'

const POLL_MS = 1000

/** The ROS 2 node, its Zenoh link, every topic it published with its live rate, and the services it answers. */
export default function Ros2Page() {
  const [node, setNode] = useState(null)
  const [error, setError] = useState(null)

  useEffect(() => {
    let live = true
    const load = () =>
      fetchRos2Node()
        .then((next) => live && (setNode(next), setError(null)))
        .catch((failure) => live && setError(failure.message))
    load()
    const timer = setInterval(load, POLL_MS)
    return () => {
      live = false
      clearInterval(timer)
    }
  }, [])

  return (
    <PageFrame title="ROS 2" summary="What this unit publishes to ROS 2, through Zenoh.">
      {error ? <p role="alert" className="ovcs-status ovcs-status--error text-sm">{error}</p> : null}
      {node ? (
        <>
          <OvcsCard className="flex flex-wrap items-center gap-x-8 gap-y-2">
            <div className="flex flex-col">
              <span className="text-xs text-ovcs-muted">node</span>
              <code className="font-semibold">{node.name}</code>
            </div>
            <div className="flex flex-col">
              <span className="text-xs text-ovcs-muted">Zenoh link</span>
              <OvcsStatus tone={node.connected ? 'ok' : 'error'} className="font-semibold">
                {node.connected ? 'connected' : 'disconnected'}
              </OvcsStatus>
            </div>
            <div className="flex flex-col">
              <span className="text-xs text-ovcs-muted">router</span>
              <code className="font-semibold">{node.zenohEndpoint ?? '–'}</code>
            </div>
          </OvcsCard>
          <OvcsCard className="flex flex-col gap-3">
            <h3 className="font-semibold">Topics</h3>
            {node.topics.length === 0 ? (
              <p className="text-sm text-ovcs-muted">Nothing published yet.</p>
            ) : (
              <table className="w-full text-left text-sm">
                <thead className="text-xs text-ovcs-muted">
                  <tr>
                    <th className="pb-2 pr-3 font-medium">topic</th>
                    <th className="pb-2 pr-3 font-medium">type</th>
                    <th className="pb-2 text-right font-medium">rate</th>
                  </tr>
                </thead>
                <tbody className="divide-y divide-ovcs-border">
                  {node.topics.map((topic) => (
                    <tr key={topic.name} data-topic={topic.name}>
                      <td className="py-2 pr-3 font-mono text-xs">{topic.name}</td>
                      <td className="py-2 pr-3 font-mono text-xs text-ovcs-muted">{topic.messageType}</td>
                      <td className="py-2 text-right font-semibold tabular-nums">{formatNumber(topic.rateHz)} Hz</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            )}
          </OvcsCard>
          <OvcsCard className="flex flex-col gap-3">
            <h3 className="font-semibold">Services</h3>
            <table className="w-full text-left text-sm">
              <thead className="text-xs text-ovcs-muted">
                <tr>
                  <th className="pb-2 pr-3 font-medium">service</th>
                  <th className="pb-2 font-medium">type</th>
                </tr>
              </thead>
              <tbody className="divide-y divide-ovcs-border">
                {node.services.map((service) => (
                  <tr key={service.name} data-service={service.name}>
                    <td className="py-2 pr-3 font-mono text-xs">{service.name}</td>
                    <td className="py-2 font-mono text-xs text-ovcs-muted">{service.serviceType}</td>
                  </tr>
                ))}
              </tbody>
            </table>
            <p className="text-sm text-ovcs-muted">
              The pipeline&apos;s settings are ROS 2 parameters: <code className="text-ovcs-text">ros2 param list</code>, then
              for example <code className="text-ovcs-text">ros2 param set &lt;node&gt; stereo.disparity.p1 10</code>. A change
              made there is an unsaved change here too.
            </p>
          </OvcsCard>
        </>
      ) : null}
    </PageFrame>
  )
}
