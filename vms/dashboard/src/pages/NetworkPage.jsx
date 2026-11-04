import { useEffect, useRef, useState } from 'react'
import { OvcsCard, OvcsPageFrame, OvcsStatus } from '@ovcs/ui/react'
import { nextLoads } from '../network.js'
import { dashboardSocket } from '../services/socket.js'

const STATE_TONES = { UP: 'ok', DOWN: 'error' }

const COUNTERS = [
  [
    'RX',
    'rx',
    [
      ['bytes', 'Bytes'],
      ['dropped', 'Dropped'],
      ['errors', 'Errors'],
      ['multicast', 'Multicast'],
      ['over_errors', 'Over errors'],
      ['packets', 'Packets']
    ]
  ],
  [
    'RX errors',
    'rx',
    [
      ['length_errors', 'Length'],
      ['crc_errors', 'CRC'],
      ['frame_errors', 'Frame'],
      ['fifo_errors', 'FIFO'],
      ['missed_errors', 'Missed']
    ]
  ],
  [
    'TX',
    'tx',
    [
      ['bytes', 'Bytes'],
      ['carrier_errors', 'Carrier errors'],
      ['collisions', 'Collisions'],
      ['dropped', 'Dropped'],
      ['errors', 'Errors'],
      ['packets', 'Packets']
    ]
  ],
  [
    'TX errors',
    'tx',
    [
      ['aborted_errors', 'Aborted'],
      ['fifo_errors', 'FIFO'],
      ['window_errors', 'Window'],
      ['heartbeat_errors', 'Heartbeat'],
      ['carrier_changes', 'Carrier changes']
    ]
  ]
]

// The interfaces, pushed every second, with each CAN interface's load.
function useNetworkInterfaces() {
  const [state, setState] = useState({ interfaces: null, loads: {} })
  const previousBytes = useRef({})

  useEffect(() => {
    const channel = dashboardSocket.channel('network-interfaces', { interval: 1000 })
    channel.on('updated', ({ data }) => {
      const { loads, bytes } = nextLoads(data, previousBytes.current)
      previousBytes.current = bytes
      setState({ interfaces: data, loads })
    })
    channel.join()
    return () => channel.leave()
  }, [])

  return state
}

function Load({ load }) {
  if (load === undefined) return <span className="text-ovcs-muted">—</span>
  return (
    <span className="flex items-center gap-2">
      <span className="h-2 w-20 overflow-hidden rounded-full bg-ovcs-border">
        <span className="block h-full rounded-full bg-ovcs-accent" style={{ width: `${Math.min(Math.max(load, 0), 100)}%` }} />
      </span>
      <span className="tabular-nums">{load} %</span>
    </span>
  )
}

function InterfacesTable({ interfaces, loads }) {
  return (
    <OvcsCard className="flex flex-col gap-3">
      <h3 className="font-semibold">Interfaces</h3>
      {/* The scroll is inside the card: a scrolling flex item in the page frame would shrink to nothing. */}
      <div className="overflow-x-auto">
        <table className="w-full text-left text-sm">
          <thead className="text-xs text-ovcs-muted">
            <tr>
              {['Network', 'Interface', 'SPI interface', 'State', 'Bitrate', 'TX queue length', 'Load'].map((title) => (
                <th key={title} scope="col" className="whitespace-nowrap pb-2 pr-3 font-medium">
                  {title}
                </th>
              ))}
            </tr>
          </thead>
          <tbody className="divide-y divide-ovcs-border">
            {interfaces.map(({ id, attributes }) => {
              const { statistics } = attributes
              return (
                <tr key={id}>
                  <th scope="row" className="py-2 pr-3 font-semibold">
                    {attributes.networkName}
                  </th>
                  <td className="py-2 pr-3 font-mono text-xs">{attributes.interfaceName}</td>
                  <td className="py-2 pr-3 font-mono text-xs">{attributes.spiInterfaceName}</td>
                  <td className="py-2 pr-3">
                    <OvcsStatus tone={STATE_TONES[statistics.operstate] ?? 'muted'}>{statistics.operstate}</OvcsStatus>
                  </td>
                  <td className="py-2 pr-3 tabular-nums">{attributes.bitrate}</td>
                  <td className="py-2 pr-3 tabular-nums">{statistics.txqlen}</td>
                  <td className="py-2">
                    <Load load={loads[statistics.ifindex]} />
                  </td>
                </tr>
              )
            })}
          </tbody>
        </table>
      </div>
    </OvcsCard>
  )
}

function Counters({ networkInterface }) {
  const { stats64 } = networkInterface.attributes.statistics
  return (
    <OvcsCard className="flex flex-col gap-3">
      <h3 className="font-semibold">{networkInterface.attributes.interfaceName}</h3>
      {COUNTERS.map(([title, direction, fields]) => (
        <section key={title} aria-label={title} className="flex flex-col gap-1">
          <h4 className="text-xs font-semibold uppercase tracking-wide text-ovcs-muted">{title}</h4>
          <dl className="grid grid-cols-2 gap-x-4 gap-y-1 text-sm sm:grid-cols-3 lg:grid-cols-6">
            {fields.map(([field, label]) => (
              <div key={field}>
                <dt className="text-xs text-ovcs-muted">{label}</dt>
                <dd className="tabular-nums">{stats64[direction][field]}</dd>
              </div>
            ))}
          </dl>
        </section>
      ))}
    </OvcsCard>
  )
}

/** The board's network interfaces: their state and bus load, then each one's traffic counters. */
export default function NetworkPage() {
  const { interfaces, loads } = useNetworkInterfaces()

  return (
    <OvcsPageFrame title="Network" summary="The board's network interfaces, refreshed every second.">
      {interfaces ? (
        <>
          <InterfacesTable interfaces={interfaces} loads={loads} />
          {interfaces.map((networkInterface) => (
            <Counters key={networkInterface.id} networkInterface={networkInterface} />
          ))}
        </>
      ) : (
        <p className="text-sm text-ovcs-muted">Waiting for the network interfaces…</p>
      )}
    </OvcsPageFrame>
  )
}
