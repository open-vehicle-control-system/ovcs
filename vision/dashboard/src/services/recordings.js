import { apiUrl, request } from './parameters.js'

// Each outlasts the unit's own wait before it answers 504 (the `@*_timeout_ms` of `VisionCore.Ros2.BagExporter`).
const READ_TIMEOUT_MS = 10000
const START_TIMEOUT_MS = 20000
const STOP_TIMEOUT_MS = 60000
const DELETE_TIMEOUT_MS = 15000
const EJECT_TIMEOUT_MS = 20000
const FORMAT_TIMEOUT_MS = 330000

const relatedId = (resource, name) => resource.relationships?.[name]?.data?.id ?? null

const toPart = (resource) => ({ ...resource.attributes, disk: relatedId(resource, 'disk') })

const toRecording = (resource, parts) => ({
  id: resource.id,
  ...resource.attributes,
  disk: relatedId(resource, 'disk'),
  parts: (resource.relationships?.parts?.data ?? []).map((ref) => parts.get(ref.id)).filter(Boolean)
})

const partsOf = (document) =>
  new Map((document.included ?? []).filter((resource) => resource.type === 'recording-parts').map((resource) => [resource.id, toPart(resource)]))

/** The recordings, the newest first: their facts, the disk the one in progress is on, and their parts with their disks. */
export async function fetchRecordings() {
  const document = await request('recordings?include=parts', { timeoutMs: READ_TIMEOUT_MS })
  const parts = partsOf(document)
  return document.data.map((resource) => toRecording(resource, parts))
}

/** The recording `id`, as `fetchRecordings` reads each. */
export async function fetchRecording(id) {
  const document = await request(`recordings/${encodeURIComponent(id)}?include=parts`, { timeoutMs: READ_TIMEOUT_MS })
  return toRecording(document.data, partsOf(document))
}

/** Starts a recording of `preset` on `clock`, and answers it. */
export async function startRecording({ preset, clock }) {
  const document = await request('recordings', {
    method: 'POST',
    body: { data: { type: 'recordings', attributes: { preset, clock } } },
    timeoutMs: START_TIMEOUT_MS
  })
  return toRecording(document.data, new Map())
}

/** Stops the recording `id`. */
export function stopRecording(id) {
  return request(`recordings/${encodeURIComponent(id)}`, {
    method: 'PATCH',
    body: { data: { type: 'recordings', id, attributes: { state: 'stopped' } } },
    timeoutMs: STOP_TIMEOUT_MS
  })
}

/** Deletes every part of the recording `id`. */
export function deleteRecording(id) {
  return request(`recordings/${encodeURIComponent(id)}`, { method: 'DELETE', timeoutMs: DELETE_TIMEOUT_MS })
}

/** Where the browser downloads the recording `id`, one tar it saves as it comes. */
export const recordingDownloadUrl = (id) => apiUrl(`recordings/${encodeURIComponent(id)}/download`)

/** The disks, in the order recordings fill them, then those the unit cannot use. */
export async function fetchDisks() {
  const document = await request('disks')
  return document.data.map((resource) => ({ id: resource.id, ...resource.attributes }))
}

/** Changes the disk `id`'s `position` in the order or whether it is `enabled`. */
export function changeDisk(id, attributes) {
  return request(`disks/${encodeURIComponent(id)}`, { method: 'PATCH', body: { data: { type: 'disks', id, attributes } } })
}

const diskRelationship = (id) => ({ disk: { data: { type: 'disks', id } } })

/** Unmounts the disk `id`, so it can be pulled out. */
export function ejectDisk(id) {
  return request('disk-ejects', {
    method: 'POST',
    body: { data: { type: 'disk-ejects', relationships: diskRelationship(id) } },
    timeoutMs: EJECT_TIMEOUT_MS
  })
}

/** Erases the disk `id` and makes it an f2fs disk labelled `label`. */
export function formatDisk(id, label) {
  return request('disk-formats', {
    method: 'POST',
    body: { data: { type: 'disk-formats', attributes: { label }, relationships: diskRelationship(id) } },
    timeoutMs: FORMAT_TIMEOUT_MS
  })
}
