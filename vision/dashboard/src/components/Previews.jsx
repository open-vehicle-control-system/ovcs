import { useEffect, useState } from 'react'
import Preview from './Preview.jsx'
import { OvcsStatus } from '@ovcs/ui/react'
import { StatusValue } from './UnitStatus.jsx'
import DepthRange from './DepthRange.jsx'
import DetectionOverlay from './DetectionOverlay.jsx'
import Hint from './Hint.jsx'
import { cameraFigures, depthFigures, objectFigures, pairStatus } from '../status.js'

const PAIR_TITLES = [
  ['sync', 'Synchronisation'],
  ['alignment', 'Row alignment'],
  ['sharpness', 'Sharpness, right / left']
]

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
              {value}
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

/** How the cameras compare, stacked between their previews; a dash until the first status. */
function PairStatus({ status }) {
  const items = status ? pairStatus(status) : PAIR_TITLES.map(([id, title]) => ({ id, title }))

  return (
    <ul aria-label="Camera pair" className="flex w-44 flex-col gap-3 text-center">
      {items.map((item) => (
        <li key={item.id} data-card={item.id} className="flex flex-col items-center">
          <p className="flex items-center gap-1 text-xs font-medium text-ovcs-muted">
            {item.title}
            <Hint hint={item.hint} />
          </p>
          {item.value === undefined ? <span className="text-ovcs-muted">–</span> : <StatusValue item={item} />}
        </li>
      ))}
    </ul>
  )
}

/** The latest detection result, `null` until one comes or on a unit without detection. */
function useDetections(socket) {
  const [detections, setDetections] = useState(null)

  useEffect(() => {
    const channel = socket.channel('detections', {})
    channel.on('detections', (payload) => setDetections(payload.detections))
    channel.join()
    return () => {
      channel.leave()
      setDetections(null)
    }
  }, [socket])

  return detections
}

/** The left camera with the detected objects drawn over it and counted; their results re-render it alone. */
function LeftPreview({ status, socket }) {
  const detections = useDetections(socket)

  return (
    <Preview stream="left" socket={socket} overlay={detections ? <DetectionOverlay detections={detections} /> : null}>
      {status ? <Figures id="left" figures={[...cameraFigures(status.cameras?.left), ...objectFigures(detections)]} /> : null}
    </Preview>
  )
}

/** Both cameras with their rates and how they compare between them, then the depth with its rate, filling the height left. */
export default function Previews({ status, socket }) {
  const [depthChannel, setDepthChannel] = useState(null)

  return (
    <section aria-label="Previews" className="flex flex-col gap-3 lg:min-h-0 lg:flex-1">
      <div className="grid shrink-0 grid-cols-[minmax(0,1fr)_auto_minmax(0,1fr)] items-center gap-3">
        <LeftPreview status={status} socket={socket} />
        <PairStatus status={status} />
        <Preview stream="right" socket={socket}>
          {status ? <Figures id="right" figures={cameraFigures(status.cameras?.right)} /> : null}
        </Preview>
      </div>
      <Preview
        stream="depth"
        socket={socket}
        onChannel={setDepthChannel}
        className="lg:flex lg:min-h-0 lg:flex-1 lg:flex-col"
        frameClassName="lg:aspect-auto lg:min-h-0 lg:flex-1"
      >
        <Figures id="depth" figures={status ? depthFigures(status.depth_hz, status.quality) : []}>
          <DepthRange channel={depthChannel} />
        </Figures>
      </Preview>
    </section>
  )
}
