import { request } from './parameters.js'

const related = (document, name) => {
  const included = new Map((document.included ?? []).map((resource) => [`${resource.type}/${resource.id}`, resource]))
  return (document.data.relationships?.[name]?.data ?? [])
    .map((ref) => included.get(`${ref.type}/${ref.id}`)?.attributes)
    .filter(Boolean)
}

/** The unit's ROS 2 node: `name`, `zenohEndpoint`, `connected`, `clockSynchronized`, `dropsBeforeClockSynchronized`, its `topics` and its `services`. */
export async function fetchRos2Node() {
  const document = await request('ros2-node?include=topics,services')
  return { ...document.data.attributes, topics: related(document, 'topics'), services: related(document, 'services') }
}

/** The firmware the unit runs: `revision`, `target`, `nervesSystem`, `nervesSystemVersion` and `vehicle`. */
export async function fetchFirmware() {
  const document = await request('firmware')
  return document.data.attributes
}

/** The board the unit runs on, as the `GET /api/board` document every API serves, which `useOvcsBoard` reads. */
export function fetchBoard() {
  return request('board')
}

/** Sets the depth video's colour range, in metres, 0 for infinitely far, and answers the one in force. */
export async function setDepthRange(metres) {
  const document = await request('depth-preview', {
    method: 'PATCH',
    body: { data: { type: 'depth-previews', id: 'current', attributes: { colourRangeM: metres } } }
  })
  return document.data.attributes.colourRangeM
}

/** What takes the outputs out of the unit: each exporter's `id`, `name`, `module`, `outputs` and `actions`, the API last. */
export async function fetchExporters() {
  const document = await request('exporters')
  return document.data.map((resource) => ({ id: resource.id, ...resource.attributes }))
}

// An action may gather a file before it answers.
const ACTION_TIMEOUT_MS = 60000

const FILENAME = /filename="([^"]*)"/
const JSON_ANSWER = /^application\/(vnd\.api\+)?json\b/

// `content-disposition` is not readable across origins unless the API exposes it, so a file is told from a JSON
// result by its readable content type.
const answerAction = async (response) => {
  if (JSON_ANSWER.test(response.headers.get('content-type') ?? '')) {
    const document = await response.json()
    return { kind: 'json', data: document.data.attributes }
  }
  const named = FILENAME.exec(response.headers.get('content-disposition') ?? '')
  return { kind: 'file', blob: await response.blob(), filename: named ? decodeURIComponent(named[1]) : 'download' }
}

/**
 * Runs the action `name` of the exporter `id`: the file it answers, as `{kind: 'file', blob, filename}`, or its JSON
 * result, as `{kind: 'json', data}`. Throws the error's message when it fails.
 */
export function runExporterAction(id, name) {
  return request(`exporters/${encodeURIComponent(id)}/actions/${encodeURIComponent(name)}`, {
    method: 'POST',
    body: { data: { type: 'exporter-actions' } },
    answer: answerAction,
    timeoutMs: ACTION_TIMEOUT_MS
  })
}
