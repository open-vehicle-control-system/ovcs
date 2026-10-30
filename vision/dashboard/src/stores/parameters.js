import { create } from 'zustand'
import * as service from '../services/parameters.js'

let timer = null
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

  exportSnippet: () => service.fetchExport(),

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
      groups: snapshot.groups,
      parameters,
      unsaved: snapshot.unsaved,
      ...(state.errorSource === 'load' ? { error: null, errorSource: null } : {})
    }))
  } catch (error) {
    set({ error: message(error), errorSource: 'load' })
  }
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

export const orderedGroups = (state) => [...state.groups].sort((a, b) => a.position - b.position)
export const flowGroups = (state) => orderedGroups(state).filter((group) => group.placement === 'flow')
export const sideGroups = (state) => orderedGroups(state).filter((group) => group.placement === 'side')

export const groupParameters = (state, groupId) => {
  const group = state.groups.find((candidate) => candidate.id === groupId)
  if (!group) return EMPTY
  return group.parameterIds.map((id) => state.parameters[id]).filter(Boolean)
}

export const groupUnsaved = (state, groupId) =>
  groupParameters(state, groupId).filter((parameter) => parameter.state === 'unsaved').length
