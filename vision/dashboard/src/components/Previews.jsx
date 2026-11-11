import { useCallback, useEffect, useState } from 'react'
import Preview from './Preview.jsx'
import { OvcsStatus } from '@ovcs/ui/react'
import { HealthValue, WARNING, Widest } from './UnitStatus.jsx'
import DepthRange from './DepthRange.jsx'
import DetectionOverlay from './DetectionOverlay.jsx'
import Hint from './Hint.jsx'
import { useExporters } from '../stores/exporters.js'
import {
  PAIR_CHECKS,
  cameraFigures,
  cameraIssues,
  depthFigures,
  depthIssues,
  objectFigures,
  pairStatus
} from '../status.js'

// Each figure is a small label over its value; the one with a tone carries the stream's health dot.
function Figures({ id, figures, children }) {
  return (
    <div data-card={id} className="flex flex-wrap items-end gap-x-4 gap-y-1">
      {figures.map(({ label, value, tone, hint }) => (
        <div key={label} data-figure={label} className="flex flex-col">
          <span className="flex items-center gap-1 text-xs text-ovcs-muted">
            {label}
            <Hint hint={hint} />
          </span>
          {tone ? (
            <OvcsStatus tone={tone} className="text-base font-semibold tabular-nums">
              <HealthValue tone={tone}>{value}</HealthValue>
            </OvcsStatus>
          ) : (
            <span className="text-base font-semibold tabular-nums">{value}</span>
          )}
        </div>
      ))}
      {children}
    </div>
  )
}

// The gauge's track spans twice a check's threshold toward each camera; its middle half is healthy.
const GAUGE_SPAN = 2

/** Where a check stands, as the unit places it: a cursor on a track from the left camera to the right one. */
function Gauge({ value, tone }) {
  const position = value == null ? null : 50 + (Math.max(-GAUGE_SPAN, Math.min(GAUGE_SPAN, value)) / GAUGE_SPAN) * 50

  return (
    <div data-gauge className="flex items-center gap-1 text-[10px] font-medium text-ovcs-muted">
      <span aria-hidden="true">L</span>
      <div className="relative h-3 flex-1">
        <div className="absolute inset-x-0 top-1/2 h-1 -translate-y-1/2 rounded-full bg-ovcs-border" />
        <div className="absolute left-1/4 right-1/4 top-1/2 h-1 -translate-y-1/2 rounded-full bg-ovcs-ok opacity-40" />
        <div className="absolute left-1/2 top-0 h-3 w-px bg-ovcs-muted" />
        {position == null ? null : (
          <div
            data-cursor
            style={{ left: `${position}%` }}
            className={`absolute top-1/2 size-3 -translate-x-1/2 -translate-y-1/2 rounded-full ring-2 ring-ovcs-surface ${
              tone === 'error' ? 'bg-ovcs-warn' : 'bg-ovcs-ok'
            }`}
          />
        )}
      </div>
      <span aria-hidden="true">R</span>
    </div>
  )
}

// One check in three lines that keep their size: its value, as wide as its widest form, its gauge, then its short
// detail; more figures and its issues on hover.
function PairCheck({ item }) {
  const tone = item.tone ?? (item.healthy ? 'ok' : 'error')
  const title = [item.more, ...item.issues].filter(Boolean).join('\n')

  return (
    <li data-card={item.id} title={title || undefined} className="flex flex-col gap-0.5">
      <div className="flex items-center justify-between gap-2">
        <span className="flex items-center gap-1 text-xs font-medium text-ovcs-muted">
          {item.title}
          <Hint hint={item.hint} />
        </span>
        <OvcsStatus tone={tone} className="font-semibold tabular-nums">
          <Widest widest={item.widest} align="end">
            {item.value}
          </Widest>
          {/* The sign keeps its room while the check is healthy. */}
          <span data-warning-slot className="flex size-3.5 shrink-0">
            {tone === 'error' ? WARNING : null}
          </span>
        </OvcsStatus>
      </div>
      <Gauge value={item.gauge} tone={tone} />
      <span data-detail className="h-4 truncate text-xs text-ovcs-muted tabular-nums">
        {item.detail || '\u00a0'}
      </span>
    </li>
  )
}

/** How the cameras work together, as the unit judges them, one line a check between their previews; a dash until the first status. */
function PairStatus({ status }) {
  const items = status ? pairStatus(status) : PAIR_CHECKS.map((check) => ({ ...check, value: '–', tone: 'muted', issues: [] }))

  return (
    <ul aria-label="Camera pair" className="flex w-52 flex-col gap-3">
      {items.map((item) => (
        <PairCheck key={item.id} item={item} />
      ))}
    </ul>
  )
}

/** What to do, as badges on a preview's frame, the full wording on hover; none without anything to do. */
function badges({ actions, wording }) {
  if (actions.length === 0) return null

  return actions.map((action) => (
    <span
      key={action}
      data-badge
      title={wording.join('\n')}
      className="rounded bg-ovcs-warn px-1.5 py-0.5 text-xs font-semibold text-black shadow"
    >
      {action}
    </span>
  ))
}

// Whether a preview has something to do, for the ring around its frame.
const needsAction = ({ actions }) => actions.length > 0

const DETECTIONS = 'detections'

/** The detection channels to join: each `detections` output the API exporter lists, the default pipeline's and every named one's. */
function useDetectionTopics() {
  const outputs = useExporters((state) => state.exporters.find((exporter) => exporter.id === 'api')?.outputs)

  return (outputs ?? []).map(({ name }) => name).filter((name) => name === DETECTIONS || name.startsWith(`${DETECTIONS}:`))
}

/** The latest detection result of each channel in `topics`, a space-separated list, by topic; a channel has none until its first comes or while its pipeline is unavailable. */
function useDetections(socket, topics) {
  const [detections, setDetections] = useState({})

  useEffect(() => {
    const channels = topics
      .split(' ')
      .filter(Boolean)
      .map((topic) => {
        const channel = socket.channel(topic, {})
        channel.on('detections', (payload) => setDetections((latest) => ({ ...latest, [topic]: payload.detections })))
        channel.join()
        return channel
      })
    return () => {
      channels.forEach((channel) => channel.leave())
      setDetections({})
    }
  }, [socket, topics])

  return detections
}

/** The left camera with every pipeline's detected objects drawn over it and counted; their results re-render it alone. */
function LeftPreview({ status, socket }) {
  const topics = useDetectionTopics()
  const latest = useDetections(socket, topics.join(' '))
  const answered = topics.filter((topic) => latest[topic])
  const detections = answered.length > 0 ? answered.flatMap((topic) => latest[topic]) : null

  return (
    <Preview
      stream="left"
      socket={socket}
      overlay={
        answered.length > 0
          ? answered.map((topic) => <DetectionOverlay key={topic} detections={latest[topic]} />)
          : null
      }
      badge={badges(cameraIssues(status?.cameras?.left))}
      alert={needsAction(cameraIssues(status?.cameras?.left))}
    >
      {status ? <Figures id="left" figures={[...cameraFigures(status.cameras?.left), ...objectFigures(detections)]} /> : null}
    </Preview>
  )
}

/**
 * The depth with its rate, its checks and quality, badged with what to do about it, and its colour range, which the unit pushes after every join, a rejoin
 * included, and on every change; the handler is bound before the join, so it misses none.
 */
function DepthPreview({ status, socket }) {
  const [channel, setChannel] = useState(null)
  const [metres, setMetres] = useState(null)

  const follow = useCallback((next) => {
    if (next) next.on('depth_range', (range) => setMetres(range.metres))
    else setMetres(null)
    setChannel(next)
  }, [])

  return (
    <Preview
      stream="depth"
      socket={socket}
      onChannel={follow}
      className="lg:flex lg:min-h-0 lg:flex-1 lg:flex-col"
      frameClassName="lg:aspect-auto lg:min-h-0 lg:flex-1"
      badge={badges(depthIssues(status))}
      alert={needsAction(depthIssues(status))}
    >
      <Figures id="depth" figures={status ? depthFigures(status) : []}>
        <DepthRange channel={channel} metres={metres} onChange={setMetres} />
      </Figures>
    </Preview>
  )
}

/** Both cameras with their rates and how they compare between them, then the depth with its rate, filling the height left. */
export default function Previews({ status, socket }) {
  return (
    <section aria-label="Previews" className="flex flex-col gap-3 lg:min-h-0 lg:flex-1">
      <div className="grid shrink-0 grid-cols-[minmax(0,1fr)_auto_minmax(0,1fr)] items-center gap-3">
        <LeftPreview status={status} socket={socket} />
        <PairStatus status={status} />
        <Preview
          stream="right"
          socket={socket}
          badge={badges(cameraIssues(status?.cameras?.right))}
          alert={needsAction(cameraIssues(status?.cameras?.right))}
        >
          {status ? <Figures id="right" figures={cameraFigures(status.cameras?.right)} /> : null}
        </Preview>
      </div>
      <DepthPreview status={status} socket={socket} />
    </section>
  )
}
