import { useCallback, useEffect, useLayoutEffect, useRef, useState } from 'react'
import Preview from './Preview.jsx'
import { OvcsStatus } from '@ovcs/ui/react'
import { HealthValue, WARNING, Widest } from './UnitStatus.jsx'
import DepthRange from './DepthRange.jsx'
import DetectionOverlay from './DetectionOverlay.jsx'
import SegmentationOverlay, { SegmentationLegend } from './SegmentationOverlay.jsx'
import Hint from './Hint.jsx'
import { useExporters } from '../stores/exporters.js'
import { decodeSegmentation } from '../segmentation.js'
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
function Figures({ id, figures }) {
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
    <ul aria-label="Camera pair" className="row-span-3 flex w-52 flex-col gap-3 self-center">
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

// A preview's part of its row's tracks, frame, caption and aside: always beside the pair's checks, from `lg` in the
// depth's row, whose previews stack below it. Its column shrinks below its content's width, as the card does.
const PAIR_TILE = 'row-span-3 grid grid-cols-[minmax(0,1fr)] grid-rows-subgrid'
const ROW_TILE = 'lg:row-span-3 lg:grid lg:grid-cols-[minmax(0,1fr)] lg:grid-rows-subgrid'
const ROW_FRAME = 'lg:aspect-auto lg:min-h-0'
// Beside the frame, the aside takes the frame's track in a column of its own, as wide in every preview of the row, and
// scrolls what its track cannot hold.
const ASIDE_REM = 14
const ROW_TILE_BESIDE = 'lg:row-span-3 lg:grid lg:grid-cols-[minmax(0,1fr)_14rem] lg:grid-rows-subgrid'
const ROW_ASIDE_BESIDE = 'lg:col-start-2 lg:row-start-1 lg:min-h-0 lg:overflow-y-auto lg:pt-2'

/**
 * Whether the asides of the row `ref` holds go beside their frames: when the frame left beside an aside would be at
 * least as wide as tall. Its previews are as wide and as tall as each other, and their captions span them either way,
 * so the first one's size and caption decide; measured again as the row or that caption resizes, or the row's
 * `previews`, their number, change, and never without `ResizeObserver`.
 */
function useBeside(ref, previews) {
  const [beside, setBeside] = useState(false)

  useLayoutEffect(() => {
    const preview = ref.current?.firstElementChild
    const caption = preview?.querySelector('figcaption')
    if (!caption || typeof ResizeObserver === 'undefined') return undefined
    const rem = parseFloat(getComputedStyle(document.documentElement).fontSize) || 16
    const observer = new ResizeObserver(() =>
      setBeside(preview.offsetWidth - ASIDE_REM * rem >= preview.offsetHeight - caption.offsetHeight)
    )
    observer.observe(ref.current)
    observer.observe(caption)
    return () => observer.disconnect()
  }, [ref, previews])

  return beside
}

/** The classes of a preview of the depth's row, its aside beside its frame or under its caption. */
const rowLayout = (beside) =>
  beside
    ? { className: ROW_TILE_BESIDE, frameClassName: ROW_FRAME, asideClassName: ROW_ASIDE_BESIDE }
    : { className: ROW_TILE, frameClassName: ROW_FRAME }

const DETECTIONS = 'detections'

/**
 * The detection channels to join on the preview of `source`, `left` or a camera's name: each `detections` output the
 * API exporter lists whose pipeline's source it is, `left` when the API names none.
 */
function useDetectionTopics(source) {
  const outputs = useExporters((state) => state.exporters.find((exporter) => exporter.id === 'api')?.outputs)

  return (outputs ?? [])
    .filter(({ name }) => name === DETECTIONS || name.startsWith(`${DETECTIONS}:`))
    .filter((output) => (output.source ?? 'left') === source)
    .map(({ name }) => name)
}

/** The latest results of the detection channels drawn on the preview of `source`: their overlays, and all their objects, `null` before any answers. */
function useSourceDetections(socket, source) {
  const topics = useDetectionTopics(source)
  const latest = useDetections(socket, topics.join(' '))
  const answered = topics.filter((topic) => latest[topic])

  return {
    overlay:
      answered.length > 0 ? answered.map((topic) => <DetectionOverlay key={topic} detections={latest[topic]} />) : null,
    detections: answered.length > 0 ? answered.flatMap((topic) => latest[topic]) : null
  }
}

const SEGMENTATION = 'segmentation:'

/** The segmentation channels to join on the preview of the camera `source`: each `segmentation` output the API exporter lists on it. */
function useSegmentationTopics(source) {
  const outputs = useExporters((state) => state.exporters.find((exporter) => exporter.id === 'api')?.outputs)

  return (outputs ?? []).filter((output) => output.name.startsWith(SEGMENTATION) && output.source === source).map(({ name }) => name)
}

// How long a class stays shown present in a pipeline's legend after its last grid with it, so its styling does not flicker at the grids' rate.
const PRESENCE_HOLD_MS = 1000

/** Each class id seen in the last `PRESENCE_HOLD_MS`, by the time it was last seen, with those of `segmentation` seen at `now`. */
function seenClasses(seen = {}, segmentation, now) {
  const kept = Object.entries(seen).filter(([, at]) => now - at < PRESENCE_HOLD_MS)
  return Object.fromEntries([...kept, ...segmentation.present.map((id) => [id, now])])
}

/**
 * The latest result of each segmentation channel in `topics`, a space-separated list, by topic, with the pipeline's
 * classes, which the unit pushes on every join before any grid, and the classes seen lately; a channel has no result
 * until its first comes. Each grid is acked once rendered, and the unit sends the next only then.
 */
function useSegmentations(socket, topics) {
  const [segmentations, setSegmentations] = useState({})
  const channelsRef = useRef({})
  const ackedRef = useRef({})

  useEffect(() => {
    const channels = topics
      .split(' ')
      .filter(Boolean)
      .map((topic) => {
        const channel = socket.channel(topic, {})
        const update = (change) => setSegmentations((latest) => ({ ...latest, [topic]: { ...latest[topic], ...change(latest[topic]) } }))
        channel.on('classes', (classes) => update(() => ({ classes })))
        channel.on('segmentation', (payload) => {
          let segmentation
          try {
            segmentation = decodeSegmentation(payload)
          } catch {
            // Never rendered, so acked here, or the unit would send no other grid.
            channel.push('ack', {})
            return
          }
          const now = Date.now()
          update((last) => ({ segmentation, seen: seenClasses(last?.seen, segmentation, now) }))
        })
        channel.join()
        channelsRef.current[topic] = channel
        return channel
      })
    return () => {
      channels.forEach((channel) => channel.leave())
      channelsRef.current = {}
      ackedRef.current = {}
      setSegmentations({})
    }
  }, [socket, topics])

  // After the commit, so the overlay has drawn the grid it acks.
  useEffect(() => {
    for (const [topic, { segmentation }] of Object.entries(segmentations)) {
      if (segmentation && ackedRef.current[topic] !== segmentation) {
        ackedRef.current[topic] = segmentation
        channelsRef.current[topic]?.push('ack', {})
      }
    }
  }, [segmentations])

  return segmentations
}

/** The segmentation pipelines on the camera `source`: their label grids drawn over its preview, and their legends once their classes come. */
function useSourceSegmentations(socket, source) {
  const topics = useSegmentationTopics(source)
  const latest = useSegmentations(socket, topics.join(' '))
  const answered = topics.filter((topic) => latest[topic]?.segmentation)
  const named = topics.filter((topic) => latest[topic]?.classes)

  return {
    overlays: answered.map((topic) => (
      <SegmentationOverlay key={topic} segmentation={latest[topic].segmentation} classes={latest[topic].classes} />
    )),
    legends: named.map((topic) => (
      <SegmentationLegend
        key={topic}
        name={topic.slice(SEGMENTATION.length)}
        classes={latest[topic].classes}
        present={new Set(Object.keys(latest[topic].seen ?? {}).map(Number))}
      />
    ))
  }
}

const CAMERA_FRAME = 'camera_frame:'
const STEREO_SIDES = ['left', 'right']

/** The cameras of their own: each `camera_frame:<name>` output the API exporter lists, but the stereo pair's sides. */
function useCameraNames() {
  const outputs = useExporters((state) => state.exporters.find((exporter) => exporter.id === 'api')?.outputs)

  return (outputs ?? [])
    .map(({ name }) => name)
    .filter((name) => name.startsWith(CAMERA_FRAME))
    .map((name) => name.slice(CAMERA_FRAME.length))
    .filter((name) => !STEREO_SIDES.includes(name))
}

/**
 * A camera of its own, titled by its name, with its rate, exposure and gain, its segmentation pipelines' label grids
 * drawn over it with a legend of their classes, and the objects its detection pipelines detect drawn over those and counted.
 */
function CameraPreview({ name, status, socket, layout }) {
  const { overlay, detections } = useSourceDetections(socket, name)
  const { overlays, legends } = useSourceSegmentations(socket, name)
  const layers = [...overlays, ...(overlay ?? [])]
  const figures = [...(status?.cameras?.[name] ? cameraFigures(status.cameras[name]) : []), ...objectFigures(detections)]

  return (
    <Preview stream={name} socket={socket} overlay={layers.length > 0 ? layers : null} aside={legends} {...layout}>
      {figures.length > 0 ? <Figures id={name} figures={figures} /> : null}
    </Preview>
  )
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

/** The left camera with the stereo pipelines' detected objects drawn over it and counted; their results re-render it alone. */
function LeftPreview({ status, socket }) {
  const { overlay, detections } = useSourceDetections(socket, 'left')

  return (
    <Preview
      stream="left"
      socket={socket}
      overlay={overlay}
      className={PAIR_TILE}
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
function DepthPreview({ status, socket, layout }) {
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
      aside={<DepthRange channel={channel} metres={metres} onChange={setMetres} />}
      {...layout}
      badge={badges(depthIssues(status))}
      alert={needsAction(depthIssues(status))}
    >
      <Figures id="depth" figures={status ? depthFigures(status) : []} />
    </Preview>
  )
}

/**
 * Both cameras with their rates and how they compare between them, then the depth with its rate and the cameras of
 * their own side by side, filling the height left. Each preview of a row spans the row's three tracks, frame, caption
 * and aside, so its frame starts and ends level with its neighbours' whatever their captions and asides hold; in the
 * depth's row, the asides go beside the frames where those keep a frame at least as wide as tall (`useBeside`).
 */
export default function Previews({ status, socket }) {
  const cameras = useCameraNames()
  const rowRef = useRef(null)
  const layout = rowLayout(useBeside(rowRef, cameras.length))

  return (
    <section aria-label="Previews" className="flex flex-col gap-3 lg:min-h-0 lg:flex-1">
      {/* The asides' track takes the height the pair's checks add, under the captions. */}
      <div className="grid shrink-0 grid-cols-[minmax(0,1fr)_auto_minmax(0,1fr)] grid-rows-[auto_auto_1fr] gap-x-3 gap-y-0">
        <LeftPreview status={status} socket={socket} />
        <PairStatus status={status} />
        <Preview
          stream="right"
          socket={socket}
          className={PAIR_TILE}
          badge={badges(cameraIssues(status?.cameras?.right))}
          alert={needsAction(cameraIssues(status?.cameras?.right))}
        >
          {status ? <Figures id="right" figures={cameraFigures(status.cameras?.right)} /> : null}
        </Preview>
      </div>
      <div
        ref={rowRef}
        data-cameras
        className="grid gap-3 lg:min-h-0 lg:flex-1 lg:auto-cols-fr lg:grid-flow-col lg:grid-rows-[minmax(0,1fr)_auto_auto] lg:gap-y-0"
      >
        <DepthPreview status={status} socket={socket} layout={layout} />
        {cameras.map((name) => (
          <CameraPreview key={name} name={name} status={status} socket={socket} layout={layout} />
        ))}
      </div>
    </section>
  )
}
