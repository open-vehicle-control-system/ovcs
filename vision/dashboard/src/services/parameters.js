const MEDIA_TYPE = 'application/vnd.api+json'

const url = (path) => `${import.meta.env.VITE_BASE_URL}/api/${path}`

export async function request(path, { method = 'GET', body } = {}) {
  const response = await fetch(url(path), {
    method,
    headers: { Accept: MEDIA_TYPE, 'Content-Type': MEDIA_TYPE },
    body: body === undefined ? undefined : JSON.stringify(body)
  })
  const document = await response.json().catch(() => ({}))
  if (!response.ok) {
    throw new Error(document.errors?.[0]?.detail ?? `${method} /api/${path}: ${response.status}`)
  }
  return document
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

export async function fetchComposerSnippet() {
  const document = await request('composer-snippet')
  return document.data.attributes.snippet
}
