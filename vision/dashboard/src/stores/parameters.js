import { create } from 'zustand'
import * as service from '../services/parameters.js'

let timer = null
let loading = false
const changing = new Set()

const message = (error) => (error instanceof Error ? error.message : String(error))

export const useParameters = create((set, get) => ({
  groups: [],
  parameters: {},
  unsaved: 0,
  selectedGroupId: null,
  error: null,
  editing: new Set(),

  async load() {
    if (loading) return
    loading = true
    try {
      const snapshot = await service.fetchGroups()
      const { parameters: current, editing } = get()
      const parameters = { ...snapshot.parameters }
      for (const id of [...editing, ...changing]) {
        if (current[id] && parameters[id]) parameters[id] = current[id]
      }
      set({ groups: snapshot.groups, parameters, unsaved: snapshot.unsaved })
    } catch (error) {
      set({ error: message(error) })
    } finally {
      loading = false
    }
  },

  async set(id, value) {
    const previous = get().parameters[id]
    if (!previous) return
    const replace = (next) => set((state) => ({ parameters: { ...state.parameters, [id]: next } }))
    changing.add(id)
    replace({ ...previous, value })
    try {
      replace(await service.setParameter(id, value))
      set({ error: null })
    } catch (error) {
      replace({ ...get().parameters[id], value: previous.value })
      set({ error: message(error) })
    } finally {
      changing.delete(id)
    }
  },

  save: () => perform(service.saveParameters, set, get),
  discard: () => perform(service.discardParameters, set, get),
  reset: (target) => perform(() => service.resetParameters(target), set, get),

  exportSnippet: () => service.fetchExport(),

  startPolling(intervalMs = 1000) {
    if (timer) return
    get().load()
    timer = setInterval(() => get().load(), intervalMs)
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

  select: (groupId) => set({ selectedGroupId: groupId })
}))

async function perform(action, set, get) {
  try {
    await action()
    set({ error: null })
  } catch (error) {
    set({ error: message(error) })
    return
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
