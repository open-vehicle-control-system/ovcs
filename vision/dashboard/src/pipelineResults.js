import { useEffect, useRef, useState } from 'react'
import { useExporters } from './stores/exporters.js'
import { decodeSegmentation } from './segmentation.js'

const DETECTIONS = 'detections'

/**
 * The detection channels to join on the preview of `source`, `left` or a camera's name: each `detections` output the
 * API exporter lists whose pipeline's source it is, `left` when the API names none.
 */
export function useDetectionTopics(source) {
  const outputs = useExporters((state) => state.exporters.find((exporter) => exporter.id === 'api')?.outputs)

  return (outputs ?? [])
    .filter(({ name }) => name === DETECTIONS || name.startsWith(`${DETECTIONS}:`))
    .filter((output) => (output.source ?? 'left') === source)
    .map(({ name }) => name)
}

export const SEGMENTATION = 'segmentation:'

/** The segmentation channels to join on the preview of the camera `source`: each `segmentation` output the API exporter lists on it. */
export function useSegmentationTopics(source) {
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
export function useSegmentations(socket, topics) {
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

/** The latest detection result of each channel in `topics`, a space-separated list, by topic; a channel has none until its first comes or while its pipeline is unavailable. */
export function useDetections(socket, topics) {
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
