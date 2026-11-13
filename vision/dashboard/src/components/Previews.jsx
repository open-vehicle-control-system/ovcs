import { useCallback, useLayoutEffect, useRef, useState } from 'react'
import Preview from './Preview.jsx'
import { OvcsStatus } from '@ovcs/ui/react'
import { HealthValue } from './UnitStatus.jsx'
import PairStatus from './PairStatus.jsx'
import DepthRange from './DepthRange.jsx'
import DetectionOverlay from './DetectionOverlay.jsx'
import SegmentationOverlay, { SegmentationLegend } from './SegmentationOverlay.jsx'
import Hint from './Hint.jsx'
import { useApiOutputs } from '../stores/exporters.js'
import { setDepthRange } from '../services/unit.js'
import {
  SEGMENTATION,
  resultAt,
  useDetectionOutputs,
  useDetectionResults,
  useSegmentationOutputs,
  useSegmentationResults
} from '../pipelineResults.js'
import {
  cameraFigures,
  cameraIssues,
  depthFigures,
  depthIssues,
  objectFigures
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
// The frame has its image's shape, 16:9 before any: as wide as its preview, and from `lg` the largest that fits the
// frame's track, which its cell measures, at the top and centre of it.
const ROW_CELL = 'lg:flex lg:min-h-0 lg:items-start lg:justify-center lg:[container-type:size]'
const ROW_FRAME =
  'aspect-[var(--frame-width,16)/var(--frame-height,9)] lg:h-[min(100cqh,100cqw*var(--frame-height,9)/var(--frame-width,16))] lg:w-[min(100cqw,100cqh*var(--frame-width,16)/var(--frame-height,9))]'
// Beside the frame, the aside sits next to it in its cell, the pair centred together, as tall as the frame and
// scrolling what it cannot hold; the frame is the largest that leaves the aside's width. `ASIDE_REM` is that width
// with the gap between them, the `9rem` and `0.75rem` below.
const ASIDE_REM = 9.75
const BESIDE_CELL = 'lg:flex lg:min-h-0 lg:items-start lg:justify-center lg:gap-3 lg:[container-type:size]'
const BESIDE_FRAME =
  'aspect-[var(--frame-width,16)/var(--frame-height,9)] lg:h-[min(100cqh,(100cqw-9.75rem)*var(--frame-height,9)/var(--frame-width,16))] lg:w-[min(100cqw-9.75rem,100cqh*var(--frame-width,16)/var(--frame-height,9))]'
const BESIDE_ASIDE =
  'w-[9rem] shrink-0 overflow-y-auto py-2 lg:h-[min(100cqh,(100cqw-9.75rem)*var(--frame-height,9)/var(--frame-width,16))]'
// Tailwind's `lg`, from which the classes above apply.
const LG = '(min-width: 1024px)'

/**
 * Whether the asides of the row `ref` holds go beside their frames: from `lg`, when the frame left beside an aside
 * would be at least as wide as tall. Its previews are as wide and as tall as each other, and their captions span them
 * either way, so the first one's size and caption decide; measured again as that preview or its caption resizes or the
 * window crosses `lg`, and never without `ResizeObserver`.
 */
function useBeside(ref) {
  const [beside, setBeside] = useState(false)

  useLayoutEffect(() => {
    const preview = ref.current?.firstElementChild
    const caption = preview?.querySelector('figcaption')
    if (!caption || typeof ResizeObserver === 'undefined') return undefined
    const rem = parseFloat(getComputedStyle(document.documentElement).fontSize) || 16
    const lg = window.matchMedia?.(LG)
    const measure = () =>
      setBeside((lg?.matches ?? true) && preview.offsetWidth - ASIDE_REM * rem >= preview.offsetHeight - caption.offsetHeight)
    // Measured before the first paint: the observer's first report can come after it.
    measure()
    const observer = new ResizeObserver(measure)
    observer.observe(preview)
    observer.observe(caption)
    lg?.addEventListener('change', measure)
    return () => {
      observer.disconnect()
      lg?.removeEventListener('change', measure)
    }
  }, [ref])

  return beside
}

/** The classes of a preview of the depth's row, its aside beside its frame or under its caption. */
const rowLayout = (beside) =>
  beside
    ? { className: ROW_TILE, cellClassName: BESIDE_CELL, frameClassName: BESIDE_FRAME, asideClassName: BESIDE_ASIDE, asideBeside: true }
    : { className: ROW_TILE, cellClassName: ROW_CELL, frameClassName: ROW_FRAME }

/**
 * The results of the detection channels drawn on the preview of `source`: their overlays for the frame captured at
 * `captureUs`, each pipeline's result on that frame or the newest when `null`, and all their newest objects, `null`
 * before any answers.
 */
function useSourceDetections(socket, source) {
  const outputs = useDetectionOutputs(source)
  const { latest, history } = useDetectionResults(socket, outputs)
  const answered = outputs.map(({ name }) => name).filter((topic) => latest[topic])
  const shown = (topic, captureUs) => (captureUs === null ? latest[topic] : resultAt(history.current[topic], captureUs))

  return {
    overlays: (captureUs) =>
      answered.flatMap((topic) => {
        const detections = shown(topic, captureUs)
        return detections ? [<DetectionOverlay key={topic} detections={detections} />] : []
      }),
    detections: answered.length > 0 ? answered.flatMap((topic) => latest[topic]) : null
  }
}

/**
 * The segmentation pipelines on the camera `source`: their label grids drawn over its preview for the frame captured
 * at `captureUs`, each pipeline's grid of that frame or the newest when `null`, and their legends, `vertical` or not,
 * once their classes come.
 */
function useSourceSegmentations(socket, source, vertical) {
  const outputs = useSegmentationOutputs(source)
  const { latest, history } = useSegmentationResults(socket, outputs)
  const topics = outputs.map(({ name }) => name)
  const answered = topics.filter((topic) => latest[topic]?.segmentation)
  const named = topics.filter((topic) => latest[topic]?.classes)
  const shown = (topic, captureUs) =>
    captureUs === null ? latest[topic].segmentation : resultAt(history.current[topic], captureUs)

  return {
    overlays: (captureUs) =>
      answered.flatMap((topic) => {
        const segmentation = shown(topic, captureUs)
        return segmentation ? [<SegmentationOverlay key={topic} segmentation={segmentation} classes={latest[topic].classes} />] : []
      }),
    legends: named.map((topic) => (
      <SegmentationLegend
        key={topic}
        name={topic.slice(SEGMENTATION.length)}
        classes={latest[topic].classes}
        present={new Set(Object.keys(latest[topic].seen ?? {}).map(Number))}
        vertical={vertical}
      />
    ))
  }
}

const CAMERA_FRAME = 'camera_frame:'
const CAMERA_VIDEO = 'camera_video:'
const STEREO_SIDES = ['left', 'right']

/**
 * The cameras of their own: each camera the API exporter lists a `camera_frame:<name>` output for, then each other one
 * whose video it relays, but the stereo pair's sides.
 */
function useCameraNames(videos) {
  const outputs = useApiOutputs()
  const framed = outputs
    .map(({ name }) => name)
    .filter((name) => name.startsWith(CAMERA_FRAME))
    .map((name) => name.slice(CAMERA_FRAME.length))

  return [...new Set([...framed, ...videos])].filter((name) => !STEREO_SIDES.includes(name))
}

/** The cameras whose video the API relays: each `camera_video:<name>:<output>` output it lists. */
function useVideoCameras() {
  const outputs = useApiOutputs()

  return outputs
    .map(({ name }) => name)
    .filter((name) => name.startsWith(CAMERA_VIDEO))
    .map((name) => name.slice(CAMERA_VIDEO.length).split(':')[0])
}

/**
 * A camera of its own, titled by its name, its video where the API relays one, else its JPEG preview, with its rate,
 * exposure and gain, its segmentation pipelines' label grids drawn over it with a legend of their classes, a class a
 * row beside the frame, and the objects its detection pipelines detect drawn over those and counted. Over a video,
 * each pipeline's result is drawn on the frame it was found on.
 */
function CameraPreview({ name, status, socket, beside, video }) {
  const { overlays: boxes, detections } = useSourceDetections(socket, name)
  const { overlays: grids, legends } = useSourceSegmentations(socket, name, beside)
  const figures = [...(status?.cameras?.[name] ? cameraFigures(status.cameras[name]) : []), ...objectFigures(detections)]
  const overlay = (captureUs) => [...grids(captureUs), ...boxes(captureUs)]

  return (
    <Preview stream={name} socket={socket} video={video} overlay={overlay} aside={legends} {...rowLayout(beside)}>
      {figures.length > 0 ? <Figures id={name} figures={figures} /> : null}
    </Preview>
  )
}

/** The left camera with the stereo pipelines' detected objects drawn over it and counted; their results re-render it alone. */
function LeftPreview({ status, socket }) {
  const { overlays, detections } = useSourceDetections(socket, 'left')

  return (
    <Preview
      stream="left"
      socket={socket}
      overlay={overlays}
      className={PAIR_TILE}
      cellClassName={ROW_CELL}
      frameClassName={ROW_FRAME}
      badge={badges(cameraIssues(status?.cameras?.left))}
      alert={needsAction(cameraIssues(status?.cameras?.left))}
    >
      {status ? <Figures id="left" figures={[...cameraFigures(status.cameras?.left), ...objectFigures(detections)]} /> : null}
    </Preview>
  )
}

/**
 * The depth with its rate, its checks and quality, badged with what to do about it, and its colour range, upright beside the frame, which the unit pushes after
 * every join, a rejoin included, and on every change; the handler is bound before the join, so it misses none.
 */
function DepthPreview({ status, socket, beside }) {
  const [metres, setMetres] = useState(null)

  const follow = useCallback((channel) => {
    if (channel) channel.on('depth_range', (range) => setMetres(range.metres))
    else setMetres(null)
  }, [])

  return (
    <Preview
      stream="depth"
      socket={socket}
      onChannel={follow}
      aside={<DepthRange set={setDepthRange} metres={metres} onChange={setMetres} vertical={beside} />}
      {...rowLayout(beside)}
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
 * and aside, so its frame's track starts and ends level with its neighbours' whatever their captions and asides hold;
 * in the depth's row, each frame has its image's shape, and the asides go beside the frames where those keep a frame
 * at least as wide as tall (`useBeside`).
 */
export default function Previews({ status, socket }) {
  const videos = useVideoCameras()
  const cameras = useCameraNames(videos)
  const rowRef = useRef(null)
  const beside = useBeside(rowRef)

  return (
    <section aria-label="Previews" className="flex flex-col gap-3 lg:min-h-0 lg:flex-1">
      {/* The asides' track takes the height the pair's checks add, under the captions; from `lg` both rows share the height. */}
      <div className="grid shrink-0 grid-cols-[minmax(0,1fr)_auto_minmax(0,1fr)] grid-rows-[auto_auto_1fr] gap-x-3 gap-y-0 lg:min-h-0 lg:flex-1 lg:grid-rows-[minmax(0,1fr)_auto_auto]">
        <LeftPreview status={status} socket={socket} />
        <PairStatus status={status} />
        <Preview
          stream="right"
          socket={socket}
          className={PAIR_TILE}
          cellClassName={ROW_CELL}
          frameClassName={ROW_FRAME}
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
        <DepthPreview status={status} socket={socket} beside={beside} />
        {cameras.map((name) => (
          <CameraPreview key={name} name={name} status={status} socket={socket} beside={beside} video={videos.includes(name)} />
        ))}
      </div>
    </section>
  )
}
