const MEDIA_TYPE = 'application/vnd.api+json'

const url = (path) => `${import.meta.env.VITE_BASE_URL}/api/${path}`

const readDocument = (response) => response.json().catch(() => ({}))

// How long the unit has to answer: a read is polled again, an action may have the unit work before it answers.
const READ_TIMEOUT_MS = 5000
const ACTION_TIMEOUT_MS = 15000

const UNREACHABLE = 'Cannot reach the vision unit'
const TIMED_OUT = 'The vision unit did not answer in time'

/**
 * Sends a JSON:API request and answers its document, or what `answer` makes of an ok response; throws the first
 * error's detail, else the status, that the unit cannot be reached, or that it did not answer, body included, within
 * `timeoutMs`: the request is then aborted, so none stays pending.
 */
export async function request(path, { method = 'GET', body, answer = readDocument, timeoutMs } = {}) {
  const abort = new AbortController()
  let timedOut = false
  const timer = setTimeout(() => {
    timedOut = true
    abort.abort()
  }, timeoutMs ?? (method === 'GET' ? READ_TIMEOUT_MS : ACTION_TIMEOUT_MS))

  try {
    const response = await fetch(url(path), {
      method,
      headers: { Accept: MEDIA_TYPE, 'Content-Type': MEDIA_TYPE },
      body: body === undefined ? undefined : JSON.stringify(body),
      signal: abort.signal
    }).catch((error) => {
      // fetch rejects with a TypeError, worded by each browser, when no answer came back.
      throw error instanceof TypeError ? new Error(UNREACHABLE, { cause: error }) : error
    })
    if (!response.ok) {
      const document = await readDocument(response)
      throw new Error(document.errors?.[0]?.detail ?? `${method} /api/${path}: ${response.status}`)
    }
    const answered = await answer(response)
    // A body cut by the abort reads as an empty document.
    if (timedOut) throw new Error(TIMED_OUT)
    return answered
  } catch (error) {
    throw timedOut ? new Error(TIMED_OUT, { cause: error }) : error
  } finally {
    clearTimeout(timer)
  }
}

const relatedId = (resource, name) => resource.relationships?.[name]?.data?.id ?? null

const toParameter = (resource) => ({
  ...resource.attributes,
  id: resource.id,
  stage: relatedId(resource, 'stage'),
  controlledBy: relatedId(resource, 'controlledBy'),
  greaterThan: relatedId(resource, 'greaterThan')
})

const toGroup = (resource) => ({
  ...resource.attributes,
  id: resource.id,
  parameterIds: (resource.relationships?.parameters?.data ?? []).map((ref) => ref.id)
})

export async function fetchGroups() {
  const document = await request('stages?include=parameters')
  const parameters = {}
  for (const resource of document.included ?? []) {
    if (resource.type === 'parameters') parameters[resource.id] = toParameter(resource)
  }
  return { groups: document.data.map(toGroup), parameters, unsaved: document.meta?.unsaved ?? 0 }
}

export async function setParameter(id, value) {
  const document = await request(`parameters/${encodeURIComponent(id)}`, {
    method: 'PATCH',
    body: { data: { type: 'parameters', id, attributes: { value } } }
  })
  return toParameter(document.data)
}

const act = async (type, target) => {
  const data = { type }
  if (target) data.relationships = { target: { data: { type: target.type, id: target.id } } }
  const document = await request(type, { method: 'POST', body: { data } })
  return document.data.attributes.parameters
}

export const saveParameters = () => act('parameter-saves')
export const discardParameters = () => act('parameter-discards')
export const resetParameters = (target) => act('parameter-resets', target)
