const relatedId = (resource, name) => resource.relationships?.[name]?.data?.id ?? null

/** A `parameters` resource as the dashboard keeps it, with the ids of its stage and of the parameters it relates to. */
export const toParameter = (resource) => ({
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

/**
 * The groups, the parameters by id and the unsaved count of a `stages` document, as `GET /api/stages?include=parameters`
 * answers it and the `parameters` channel pushes it; `complete` false for a push of the stages that changed on their own,
 * which carries no unsaved count.
 */
export function snapshotOf(document) {
  const parameters = {}
  for (const resource of document.included ?? []) {
    if (resource.type === 'parameters') parameters[resource.id] = toParameter(resource)
  }
  return {
    groups: document.data.map(toGroup),
    parameters,
    unsaved: document.meta?.unsaved ?? 0,
    complete: document.meta?.complete !== false
  }
}
