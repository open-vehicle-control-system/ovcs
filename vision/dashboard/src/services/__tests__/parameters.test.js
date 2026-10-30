import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'
import {
  fetchGroups, setParameter, saveParameters, discardParameters, resetParameters, fetchExport
} from '../parameters.js'

const respond = (status, body) => ({ ok: status < 400, status, json: async () => body })

const parameterResource = (id, group, extra = {}) => ({
  type: 'parameters',
  id,
  attributes: { name: id, type: 'integer', value: 12, saved: 12, state: 'builtin', ...extra },
  relationships: {
    group: { data: { type: 'parameter-groups', id: group } },
    controller: { data: null },
    'greater-than': { data: null }
  }
})

const document_ = {
  data: [
    {
      type: 'parameter-groups',
      id: 'stereo.match',
      attributes: { name: 'Match', kind: 'stage', placement: 'flow', position: 1, status: null },
      relationships: { parameters: { data: [{ type: 'parameters', id: 'stereo.match.p1' }, { type: 'parameters', id: 'stereo.match.p2' }] } }
    }
  ],
  included: [
    parameterResource('stereo.match.p1', 'stereo.match'),
    parameterResource('stereo.match.p2', 'stereo.match', {
      state: 'automatic'
    })
  ],
  meta: { unsaved: 2 }
}
document_.included[1].relationships.controller = { data: { type: 'parameters', id: 'stereo.match.p1' } }
document_.included[1].relationships['greater-than'] = { data: { type: 'parameters', id: 'stereo.match.p1' } }

describe('parameters service', () => {
  let fetchMock

  beforeEach(() => {
    fetchMock = vi.fn()
    vi.stubGlobal('fetch', fetchMock)
  })
  afterEach(() => vi.unstubAllGlobals())

  const lastRequest = () => {
    const [url, options] = fetchMock.mock.calls.at(-1)
    return { url, options, body: options?.body ? JSON.parse(options.body) : undefined }
  }

  it('flattens groups and parameters out of the JSON:API document', async () => {
    fetchMock.mockResolvedValue(respond(200, document_))

    const { groups, parameters, unsaved } = await fetchGroups()

    expect(lastRequest().url).toMatch(/\/api\/parameter-groups\?include=parameters$/)
    expect(lastRequest().options.headers).toMatchObject({
      Accept: 'application/vnd.api+json',
      'Content-Type': 'application/vnd.api+json'
    })
    expect(unsaved).toBe(2)
    expect(groups).toEqual([
      expect.objectContaining({
        id: 'stereo.match', name: 'Match', placement: 'flow', position: 1,
        parameterIds: ['stereo.match.p1', 'stereo.match.p2']
      })
    ])
    expect(parameters['stereo.match.p1']).toMatchObject({
      id: 'stereo.match.p1', value: 12, group: 'stereo.match', controller: null, greaterThan: null
    })
    expect(parameters['stereo.match.p2']).toMatchObject({
      state: 'automatic', controller: 'stereo.match.p1', greaterThan: 'stereo.match.p1'
    })
  })

  it('returns the parameter a change was accepted as', async () => {
    fetchMock.mockResolvedValue(respond(200, { data: parameterResource('stereo.match.p1', 'stereo.match', { value: 8 }) }))

    const parameter = await setParameter('stereo.match.p1', 8)

    expect(parameter.value).toBe(8)
    expect(lastRequest().url).toMatch(/\/api\/parameters\/stereo\.match\.p1$/)
    expect(lastRequest().options.method).toBe('PATCH')
    expect(lastRequest().body).toEqual({
      data: { type: 'parameters', id: 'stereo.match.p1', attributes: { value: 8 } }
    })
  })

  it('throws the error detail of a refused change', async () => {
    fetchMock.mockResolvedValue(respond(422, {
      errors: [{ status: '422', title: 'Invalid value', detail: 'must be at most 15', source: { pointer: '/data/attributes/value' } }]
    }))

    await expect(setParameter('stereo.match.p1', 99)).rejects.toThrow('must be at most 15')
  })

  it('falls back to the status when the error has no detail', async () => {
    fetchMock.mockResolvedValue(respond(500, {}))

    await expect(saveParameters()).rejects.toThrow(/500/)
  })

  it('returns the ids saved and discarded', async () => {
    fetchMock.mockResolvedValue(respond(201, {
      data: { type: 'parameter-saves', id: '1', attributes: { parameters: ['a', 'b'] } }
    }))

    expect(await saveParameters()).toEqual(['a', 'b'])
    expect(lastRequest().url).toMatch(/\/api\/parameter-saves$/)
    expect(lastRequest().body).toEqual({ data: { type: 'parameter-saves' } })

    expect(await discardParameters()).toEqual(['a', 'b'])
    expect(lastRequest().url).toMatch(/\/api\/parameter-discards$/)
    expect(lastRequest().body).toEqual({ data: { type: 'parameter-discards' } })
  })

  it('sends the reset target as a relationship, and none for everything', async () => {
    fetchMock.mockResolvedValue(respond(201, {
      data: { type: 'parameter-resets', id: '2', attributes: { parameters: ['a'] } }
    }))

    await resetParameters({ type: 'parameter-groups', id: 'stereo.match' })
    expect(lastRequest().url).toMatch(/\/api\/parameter-resets$/)
    expect(lastRequest().body).toEqual({
      data: {
        type: 'parameter-resets',
        relationships: { target: { data: { type: 'parameter-groups', id: 'stereo.match' } } }
      }
    })

    await resetParameters(null)
    expect(lastRequest().body).toEqual({ data: { type: 'parameter-resets' } })
  })

  it('returns the export snippet', async () => {
    fetchMock.mockResolvedValue(respond(200, {
      data: { type: 'parameter-exports', id: 'current', attributes: { snippet: 'config :a, b: 1' } }
    }))

    expect(await fetchExport()).toBe('config :a, b: 1')
    expect(lastRequest().url).toMatch(/\/api\/parameter-export$/)
  })
})
