import { actionBody } from '../format.js'

const url = (path) => `${import.meta.env.VITE_BASE_URL ?? ''}/api/${path}`

/**
 * Sends a JSON request and answers its document, or `null` for an empty answer; throws the API's error reason, else
 * the status, or that the VMS cannot be reached.
 */
export async function request(path, { method = 'GET', body } = {}) {
  const response = await fetch(url(path), {
    method,
    headers: { Accept: 'application/json', 'Content-Type': 'application/json' },
    body: body === undefined ? undefined : JSON.stringify(body)
  }).catch((error) => {
    // fetch rejects with a TypeError, worded by each browser, when no answer came back.
    throw error instanceof TypeError ? new Error('Cannot reach the VMS', { cause: error }) : error
  })
  const document = await response
    .text()
    .then((text) => (text ? JSON.parse(text) : null))
    .catch(() => null)
  if (!response.ok) {
    const errors = document?.errors
    throw new Error(errors?.reason ?? errors?.detail ?? `${method} /api/${path}: ${response.status}`)
  }
  return document
}

const resource = ({ id, attributes }) => ({ id, ...attributes })

/** The vehicle: `name` and `refreshInterval`, the milliseconds between metric pushes. */
export async function fetchVehicle() {
  const { name, refreshInterval } = (await request('vehicle')).data.attributes
  return { name, refreshInterval }
}

/** The firmware the VMS runs: `revision`, `target`, `nervesSystem`, `nervesSystemVersion` and `vehicle`. */
export async function fetchFirmware() {
  return (await request('firmware')).data.attributes
}

/** The board the VMS runs on: its `interfaces`, each a `name` with its `addresses`, its clock's `time` and `clockSynchronized`. */
export async function fetchBoard() {
  return (await request('board')).data.attributes
}

/** The vehicle's pages, `id` and `name`, in their order. */
export async function fetchPages() {
  return (await request('vehicle/pages')).data.map(resource)
}

/** A page's blocks in their order: `id`, `name`, `subtype`, `fullWidth`, and the subtype's own attributes. */
export async function fetchBlocks(pageId) {
  return (await request(`vehicle/pages/${encodeURIComponent(pageId)}/blocks`)).data.map(resource)
}

/** Triggers an action row's action, with `value` for a number row. */
export function postAction(row, value) {
  return request('actions', { method: 'POST', body: actionBody(row, value) })
}
