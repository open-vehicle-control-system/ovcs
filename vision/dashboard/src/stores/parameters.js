import { create } from 'zustand'
import * as service from '../services/parameters.js'
import { snapshotOf } from '../services/stages.js'

let loading = null
let reloadRequested = false
let generation = 0
const changing = new Map()

const message = (error) => (error instanceof Error ? error.message : String(error))

const protect = (id) => changing.set(id, (changing.get(id) ?? 0) + 1)
const release = (id) => {
  const count = (changing.get(id) ?? 1) - 1
  if (count > 0) changing.set(id, count)
  else changing.delete(id)
}

export const useParameters = create((set, get) => ({
  groups: [],
  parameters: {},
  unsaved: 0,
  selectedGroupId: null,
  error: null,
  errorSource: null,
  editing: new Set(),

  // Callers during a load get its promise, which settles after the reload they asked for.
  load() {
    reloadRequested = true
    loading ??= loadUntilCurrent(set, get)
    return loading
  },

  async set(id, value) {
    const previous = get().parameters[id]
    if (!previous) return
    const replace = (next) => set((state) => ({ parameters: { ...state.parameters, [id]: next } }))
    protect(id)
    replace({ ...previous, value })
    try {
      const accepted = await service.setParameter(id, value)
      // Against the state shown now: an overlapping change accepted meanwhile may have updated it.
      const delta = Number(accepted.state === 'unsaved') - Number(get().parameters[id]?.state === 'unsaved')
      replace(accepted)
      set((state) => ({ unsaved: Math.max(0, state.unsaved + delta), error: null, errorSource: null }))
    } catch (error) {
      replace({ ...get().parameters[id], value: previous.value })
      set({ error: `${previous.name}: ${message(error)}`, errorSource: 'action' })
    } finally {
      release(id)
      generation += 1
    }
  },

  save: () => perform(service.saveParameters, set, get),
  discard: () => perform(service.discardParameters, set, get),
  reset: (target) => perform(() => service.resetParameters(target), set, get),

  // Follows the parameters channel, which pushes every stage on join and as they change; answers how to leave it.
  listen(socket) {
    const channel = socket.channel('parameters', {})
    channel.on('stages', (document) => receive(set, get, snapshotOf(document)))
    channel.onError(() => set({ error: service.UNREACHABLE, errorSource: 'load' }))
    channel.join()
    return () => channel.leave()
  },

  beginEdit: (id) => set((state) => ({ editing: new Set(state.editing).add(id) })),

  endEdit: (id) =>
    set((state) => {
      const editing = new Set(state.editing)
      editing.delete(id)
      return { editing }
    }),

  dismissError: () => set({ error: null, errorSource: null }),

  select: (groupId) => set({ selectedGroupId: groupId })
}))

async function loadUntilCurrent(set, get) {
  try {
    while (reloadRequested) {
      reloadRequested = false
      await loadOnce(set, get)
    }
  } finally {
    loading = null
  }
}

async function loadOnce(set, get) {
  const started = generation
  try {
    const snapshot = await service.fetchGroups()
    if (started !== generation) {
      reloadRequested = true
      return
    }
    receive(set, get, { ...snapshot, complete: true })
  } catch (error) {
    set({ error: message(error), errorSource: 'load' })
  }
}

// The stages of `snapshot` shown, all of them or, for an incomplete one, those it carries; a parameter being edited or
// changed keeps the value shown.
function receive(set, get, { groups, parameters, unsaved, complete }) {
  const { parameters: current, editing } = get()
  const next = complete ? { ...parameters } : { ...current, ...parameters }
  for (const id of [...editing, ...changing.keys()]) {
    if (current[id] && next[id]) next[id] = current[id]
  }
  set((state) => ({
    groups: keepUnchanged(state.groups, complete ? groups : replaceById(state.groups, groups)),
    parameters: keepUnchanged(state.parameters, next),
    ...(complete ? { unsaved } : {}),
    ...(state.errorSource === 'load' ? { error: null, errorSource: null } : {})
  }))
}

// `groups` with each of `updated` in place of the group of its id, any new one after them.
function replaceById(groups, updated) {
  const byId = new Map(updated.map((group) => [group.id, group]))
  const known = new Set(groups.map((group) => group.id))
  return [...groups.map((group) => byId.get(group.id) ?? group), ...updated.filter((group) => !known.has(group.id))]
}

// A push or a load mostly answers what is already shown: keeping the objects it did not change spares their components a render.
const same = (a, b) => a === b || JSON.stringify(a) === JSON.stringify(b)

// `next`, an array or an object, with each item equal to `previous`'s at the same key kept; `previous` itself if all are.
function keepUnchanged(previous, next) {
  const kept = Array.isArray(next) ? [] : {}
  let changed = Object.keys(previous).length !== Object.keys(next).length
  for (const [key, item] of Object.entries(next)) {
    kept[key] = same(previous[key], item) ? previous[key] : item
    if (kept[key] !== previous[key]) changed = true
  }
  return changed ? kept : previous
}

// A failed action may still have changed values, such as a partial reset, so it reloads too.
async function perform(action, set, get) {
  try {
    await action()
    set({ error: null, errorSource: null })
  } catch (error) {
    set({ error: message(error), errorSource: 'action' })
  } finally {
    generation += 1
  }
  await get().load()
}

const EMPTY = []

export const orderedGroups = (state) => state.groups.toSorted((a, b) => a.position - b.position)

/** The pipelines as `{ name, groups }`, each with its groups in order, in the order of their first group. */
export function pipelines(state) {
  const byName = new Map()
  for (const group of orderedGroups(state)) byName.set(group.pipeline, [...(byName.get(group.pipeline) ?? []), group])
  return Array.from(byName, ([name, groups]) => ({ name, groups }))
}

export const groupParameters = (state, groupId) => {
  const group = state.groups.find((candidate) => candidate.id === groupId)
  if (!group) return EMPTY
  return group.parameterIds.map((id) => state.parameters[id]).filter(Boolean)
}

/** Every group's unsaved count by its id, in one pass over the groups. */
export function unsavedByGroup(state) {
  const counts = {}
  for (const group of state.groups) {
    let count = 0
    for (const id of group.parameterIds) if (state.parameters[id]?.state === 'unsaved') count += 1
    counts[group.id] = count
  }
  return counts
}
