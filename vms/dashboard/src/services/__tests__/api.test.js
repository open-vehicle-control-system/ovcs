import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'
import { fetchBlocks, fetchBoard, fetchFirmware, fetchPages, fetchVehicle, postAction } from '../api.js'
import { actionBody } from '../../format.js'

const answer = (status, body = '') =>
  Promise.resolve({ ok: status >= 200 && status < 300, status, text: () => Promise.resolve(body) })

describe('api', () => {
  beforeEach(() => vi.stubGlobal('fetch', vi.fn(() => answer(201))))
  afterEach(() => vi.unstubAllGlobals())

  it('posts an action with its extra parameters and the value as a string', async () => {
    await postAction({ module: 'Elixir.M', action: 'set', extraParameters: { parameter: 'kp' } }, 0.12)

    const [url, options] = fetch.mock.calls[0]
    expect(url).toMatch(/\/api\/actions$/)
    expect(options.method).toBe('POST')
    expect(JSON.parse(options.body)).toEqual({ module: 'Elixir.M', action: 'set', parameter: 'kp', value: '0.12' })
  })

  it('sends no value when there is none', () => {
    expect(actionBody({ module: 'M', action: 'a', extraParameters: {} }, '')).toEqual({ module: 'M', action: 'a' })
    expect(actionBody({ module: 'M', action: 'a', extraParameters: {} }, null)).toEqual({ module: 'M', action: 'a' })
    expect(actionBody({ module: 'M', action: 'a', extraParameters: {} })).toEqual({ module: 'M', action: 'a' })
  })

  it('answers null for an empty 201', async () => {
    await expect(postAction({ module: 'M', action: 'a', extraParameters: {} })).resolves.toBeNull()
  })

  it("throws the API's reason on a 422", async () => {
    fetch.mockImplementation(() =>
      answer(422, JSON.stringify({ errors: { detail: 'Unprocessable Entity', reason: 'not_calibrating' } }))
    )
    await expect(postAction({ module: 'M', action: 'a', extraParameters: {} })).rejects.toThrow('not_calibrating')
  })

  it('throws the method, path and status when the answer carries no error', async () => {
    fetch.mockImplementation(() => answer(500, 'oops'))
    await expect(fetchBlocks('status')).rejects.toThrow('GET /api/vehicle/pages/status/blocks: 500')
  })

  it('says the VMS cannot be reached when fetch rejects with a TypeError', async () => {
    fetch.mockImplementation(() => Promise.reject(new TypeError('Failed to fetch')))
    await expect(fetchVehicle()).rejects.toThrow('Cannot reach the VMS')
  })

  it('reads the vehicle, the pages and the blocks from their resources', async () => {
    fetch.mockImplementation((url) => {
      if (url.endsWith('/api/vehicle')) {
        return answer(200, JSON.stringify({ data: { id: 'vehicle', attributes: { name: 'Mini', refreshInterval: 70 } } }))
      }
      if (url.endsWith('/api/vehicle/pages')) {
        return answer(200, JSON.stringify({ data: [{ type: 'page', id: 'status', attributes: { name: 'Status' } }] }))
      }
      return answer(
        200,
        JSON.stringify({ data: [{ type: 'block', id: 'motion', attributes: { name: 'Motion', subtype: 'table', rows: [] } }] })
      )
    })

    expect(await fetchVehicle()).toEqual({ name: 'Mini', refreshInterval: 70 })
    expect(await fetchPages()).toEqual([{ id: 'status', name: 'Status' }])
    expect(await fetchBlocks('status')).toEqual([{ id: 'motion', name: 'Motion', subtype: 'table', rows: [] }])
  })

  it('reads the firmware from its resource', async () => {
    const attributes = { revision: 'ce99e251', target: 'rpi4', nervesSystem: 'nerves_system_rpi4', nervesSystemVersion: '1.30.0', vehicle: 'OVCS1' }
    fetch.mockImplementation(() => answer(200, JSON.stringify({ data: { type: 'firmware', id: 'current', attributes } })))

    expect(await fetchFirmware()).toEqual(attributes)
    expect(fetch.mock.calls[0][0]).toMatch(/\/api\/firmware$/)
  })

  it('answers the board document as GET /api/board serves it, for useOvcsBoard to read', async () => {
    const document = { data: { type: 'boards', id: 'current', attributes: { interfaces: [{ name: 'eth0', addresses: ['192.168.1.20'] }], time: '2026-11-11T14:53:12Z', clockSynchronized: true } } }
    fetch.mockImplementation(() => answer(200, JSON.stringify(document)))

    expect(await fetchBoard()).toEqual(document)
    expect(fetch.mock.calls[0][0]).toMatch(/\/api\/board$/)
  })
})
