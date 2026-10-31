import { create } from 'zustand'
import * as service from '../services/parameters.js'

let timer = null
let loading = null
let reloadRequested = false
let generation = 0
const changing = new Map()

// fetch rejects with a TypeError, worded by each browser, when no answer came back.
const message = (error) => {
  if (error instanceof TypeError) return 'Cannot reach the vision unit'
  return error instanceof Error ? error.message : String(error)
}

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
      const delta = Number(accepted.state === 'unsaved') - Number(previous.state === 'unsaved')
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

  exportSnippet: () => service.fetchComposerSnippet(),

  startPolling(intervalMs = 1000) {
    if (timer) return
    const poll = () => {
      if (!loading) get().load()
    }
    poll()
    timer = setInterval(poll, intervalMs)
  },

  stopPolling() {
    clearInterval(timer)
    timer = null
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
    const { parameters: current, editing } = get()
    const parameters = { ...snapshot.parameters }
    for (const id of [...editing, ...changing.keys()]) {
      if (current[id] && parameters[id]) parameters[id] = current[id]
    }
    set((state) => ({
      groups: keepUnchanged(state.groups, snapshot.groups),
      parameters: keepUnchanged(state.parameters, parameters),
      unsaved: snapshot.unsaved,
      ...(state.errorSource === 'load' ? { error: null, errorSource: null } : {})
    }))
  } catch (error) {
    set({ error: message(error), errorSource: 'load' })
  }
}

// A poll mostly answers what is already shown: keeping the objects it did not change spares their components a render.
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
/** The groups in order, split between the pipeline's flow and the branches beside it. */
export function placedGroups(state) {
  const ordered = orderedGroups(state)
  return { flow: ordered.filter((group) => group.role !== 'branch'), side: ordered.filter((group) => group.role === 'branch') }
}

export const flowGroups = (state) => placedGroups(state).flow

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
