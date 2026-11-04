const MEDIA_TYPE = 'application/vnd.api+json'

const url = (path) => `${import.meta.env.VITE_BASE_URL}/api/${path}`

const readDocument = (response) => response.json().catch(() => ({}))

/**
 * Sends a JSON:API request and answers its document, or what `answer` makes of an ok response; throws the first
 * error's detail, else the status, or that the unit cannot be reached.
 */
export async function request(path, { method = 'GET', body, answer = readDocument } = {}) {
  const response = await fetch(url(path), {
    method,
    headers: { Accept: MEDIA_TYPE, 'Content-Type': MEDIA_TYPE },
    body: body === undefined ? undefined : JSON.stringify(body)
  }).catch((error) => {
    // fetch rejects with a TypeError, worded by each browser, when no answer came back.
    throw error instanceof TypeError ? new Error('Cannot reach the vision unit', { cause: error }) : error
  })
  if (!response.ok) {
    const document = await readDocument(response)
    throw new Error(document.errors?.[0]?.detail ?? `${method} /api/${path}: ${response.status}`)
  }
  return answer(response)
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
