import { useEffect, useRef, useState } from 'react'
import { useApiOutputs } from './stores/exporters.js'
import { decodeSegmentation } from './segmentation.js'

const DETECTIONS = 'detections'

/**
 * The detection outputs whose channels to join on the preview of `source`, `left` or a camera's name: each
 * `detections` output the API exporter lists whose pipeline's source it is, `left` when the API names none.
 */
export function useDetectionOutputs(source) {
  const outputs = useApiOutputs()

  return outputs
    .filter(({ name }) => name === DETECTIONS || name.startsWith(`${DETECTIONS}:`))
    .filter((output) => (output.source ?? 'left') === source)
}

export const SEGMENTATION = 'segmentation:'

/** The segmentation outputs whose channels to join on the preview of the camera `source`: each `segmentation` output the API exporter lists on it. */
export function useSegmentationOutputs(source) {
  const outputs = useApiOutputs()

  return outputs.filter((output) => output.name.startsWith(SEGMENTATION) && output.source === source)
}

// How long a class stays shown present in a pipeline's legend after its last grid with it, so its styling does not flicker at the grids' rate.
const PRESENCE_HOLD_MS = 1000

/** Each class id seen in the last `PRESENCE_HOLD_MS`, by the time it was last seen, with those of `segmentation` seen at `now`. */
function seenClasses(seen = {}, segmentation, now) {
  const kept = Object.entries(seen).filter(([, at]) => now - at < PRESENCE_HOLD_MS)
  return Object.fromEntries([...kept, ...segmentation.present.map((id) => [id, now])])
}

// A pipeline answers at most `maxHz` a second and can be slower: its last result is held this many periods, and
// this long at least, before it counts as quiet.
const STALE_PERIODS = 10
const STALE_FLOOR_MS = 2000

const staleMs = (maxHz) => Math.max(STALE_FLOOR_MS, maxHz ? (STALE_PERIODS * 1000) / maxHz : 0)

const without = (states, topic) => Object.fromEntries(Object.entries(states).filter(([key]) => key !== topic))

/**
 * One channel an output of `outputs`, its name the topic, joined as long as `socket` and the outputs' names and
 * `maxHz` stay, with each topic's latest state. `results.handlers(channel, update)` gives a channel's handlers by
 * event, bound before it joins, and `update(change)` sets its topic's state to `change` of the one before. A topic
 * has no state until its first update and once its channel fails, as when its pipeline restarts; a state no update
 * follows within `staleMs` of the output's `maxHz` is cut to `results.aged` of it, dropped when that is undefined.
 * Returns the states by topic and a ref to the channels by topic.
 */
function useTopicChannels(socket, outputs, results) {
  const [latest, setLatest] = useState({})
  const channelsRef = useRef({})
  // The exporters' store lists new outputs on every load: as one string, they keep the channels through a load that changes none.
  const listed = JSON.stringify(outputs.map(({ name, maxHz }) => [name, maxHz ?? null]))

  useEffect(() => {
    const channels = JSON.parse(listed).map(([topic, maxHz]) => {
      const channel = socket.channel(topic, {})
      const opened = { channel, joined: true, ageTimer: null }
      const set = (change) =>
        setLatest((states) => {
          const state = change(states[topic])
          return state === undefined ? without(states, topic) : { ...states, [topic]: state }
        })
      const update = (change) => {
        clearTimeout(opened.ageTimer)
        opened.ageTimer = setTimeout(() => set((last) => last && results.aged(last)), staleMs(maxHz))
        set(change)
      }
      opened.events = Object.entries(results.handlers(channel, update)).map(([event, handler]) => {
        channel.on(event, handler)
        return event
      })
      channel.onError(() => {
        if (!opened.joined) return
        clearTimeout(opened.ageTimer)
        set(() => undefined)
      })
      channel.join()
      channelsRef.current[topic] = channel
      return opened
    })
    return () => {
      channels.forEach((opened) => {
        opened.joined = false
        clearTimeout(opened.ageTimer)
        // An event already on its way would otherwise set a state for a channel that was left.
        opened.events.forEach((event) => opened.channel.off(event))
        opened.channel.leave()
      })
      channelsRef.current = {}
      setLatest({})
    }
  }, [socket, listed, results])

  return [latest, channelsRef]
}

const segmentationResults = {
  handlers: (channel, update) => ({
    classes: (classes) => update((last) => ({ ...last, classes })),
    segmentation: (payload) => {
      let segmentation
      try {
        segmentation = decodeSegmentation(payload)
      } catch {
        // Never rendered, so acked here, or the unit would send no other grid.
        channel.push('ack', {})
        return
      }
      const now = Date.now()
      update((last) => ({ ...last, segmentation, seen: seenClasses(last?.seen, segmentation, now) }))
    }
  }),
  // The class names come on a join alone, so they outlive the grids.
  aged: ({ classes }) => (classes ? { classes } : undefined)
}

/**
 * The latest result of the segmentation channel of each of `outputs`, by topic, with the pipeline's
 * classes, which the unit pushes on every join before any grid, and the classes seen lately; a channel has no result
 * until its first comes, nor once its pipeline goes quiet (`useTopicChannels`), which also ends its classes' presence.
 * Each grid is acked once rendered, and the unit sends the next only then.
 */
export function useSegmentations(socket, outputs) {
  const [segmentations, channelsRef] = useTopicChannels(socket, outputs, segmentationResults)
  const ackedRef = useRef(new WeakSet())

  // After the commit, so the overlay has drawn the grid it acks.
  useEffect(() => {
    for (const [topic, { segmentation }] of Object.entries(segmentations)) {
      if (segmentation && !ackedRef.current.has(segmentation)) {
        ackedRef.current.add(segmentation)
        channelsRef.current[topic]?.push('ack', {})
      }
    }
  }, [segmentations, channelsRef])

  return segmentations
}

const detectionResults = {
  handlers: (_channel, update) => ({ detections: (payload) => update(() => payload.detections) }),
  aged: () => undefined
}

/** The latest detection result of the channel of each of `outputs`, by topic; a channel has none until its first comes, nor once its pipeline goes quiet (`useTopicChannels`). */
export function useDetections(socket, outputs) {
  return useTopicChannels(socket, outputs, detectionResults)[0]
}
