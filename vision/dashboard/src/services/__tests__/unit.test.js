import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'
import { fetchExporters, fetchFirmware, fetchRos2Node, runExporterAction } from '../unit.js'

const respond = (body) => ({ ok: true, status: 200, json: async () => body })

const document_ = {
  data: {
    type: 'ros2-nodes',
    id: 'vision',
    attributes: { name: 'vision', zenohEndpoint: 'tcp/192.168.10.1:7447', connected: true },
    relationships: {
      topics: { data: [{ type: 'ros2-topics', id: '/stereo/points' }] },
      services: { data: [{ type: 'ros2-services', id: '/vision/get_parameters' }] }
    }
  },
  included: [
    {
      type: 'ros2-services',
      id: '/vision/get_parameters',
      attributes: { name: '/vision/get_parameters', serviceType: 'rcl_interfaces/srv/GetParameters' }
    },
    {
      type: 'ros2-topics',
      id: '/stereo/points',
      attributes: { name: '/stereo/points', messageType: 'sensor_msgs/msg/PointCloud2', rateHz: 9.5 }
    }
  ]
}

describe('unit service', () => {
  let fetchMock

  beforeEach(() => {
    fetchMock = vi.fn().mockResolvedValue(respond(document_))
    vi.stubGlobal('fetch', fetchMock)
  })
  afterEach(() => vi.unstubAllGlobals())

  it('reads the ROS 2 node with its topics and services from the included resources', async () => {
    expect(await fetchRos2Node()).toEqual({
      name: 'vision',
      zenohEndpoint: 'tcp/192.168.10.1:7447',
      connected: true,
      topics: [{ name: '/stereo/points', messageType: 'sensor_msgs/msg/PointCloud2', rateHz: 9.5 }],
      services: [{ name: '/vision/get_parameters', serviceType: 'rcl_interfaces/srv/GetParameters' }]
    })
    expect(fetchMock.mock.calls[0][0]).toMatch(/\/api\/ros2-node\?include=topics,services$/)
  })

  it("reads the firmware's commit, target and Nerves system", async () => {
    const attributes = { revision: 'ce99e251', target: 'okdo_c100', nervesSystem: 'nerves_system_okdo_c100', nervesSystemVersion: '0.3.0' }
    fetchMock.mockResolvedValue(respond({ data: { type: 'firmwares', id: 'current', attributes } }))

    expect(await fetchFirmware()).toEqual(attributes)
    expect(fetchMock.mock.calls[0][0]).toMatch(/\/api\/firmware$/)
  })

  it('reads the exporters, each with its id', async () => {
    const attributes = {
      name: 'ROS 2',
      module: 'VisionCore.Ros2.Exporter',
      status: { level: 'ok', detail: 'Connected' },
      outputs: [{ name: 'stereo_pair', maxHz: null }]
    }
    fetchMock.mockResolvedValue(respond({ data: [{ type: 'exporters', id: 'ros2', attributes }] }))

    expect(await fetchExporters()).toEqual([{ id: 'ros2', ...attributes }])
    expect(fetchMock.mock.calls[0][0]).toMatch(/\/api\/exporters$/)
  })

  describe('runExporterAction', () => {
    const MEDIA_TYPE = 'application/vnd.api+json'
    const answer = (status, headers, rest) => ({ ok: status < 400, status, headers: new Headers(headers), ...rest })

    it('posts the action as an exporter-actions document', async () => {
      fetchMock.mockResolvedValue(answer(200, { 'content-type': MEDIA_TYPE }, { json: async () => ({ data: { attributes: {} } }) }))

      await runExporterAction('debug', 'export')

      const [url, options] = fetchMock.mock.calls[0]
      expect(url).toMatch(/\/api\/exporters\/debug\/actions\/export$/)
      expect(options.method).toBe('POST')
      expect(options.headers['Content-Type']).toBe(MEDIA_TYPE)
      expect(JSON.parse(options.body)).toEqual({ data: { type: 'exporter-actions' } })
    })

    it('answers the file of a download, named by its content-disposition', async () => {
      const blob = new Blob(['zip'])
      fetchMock.mockResolvedValue(
        answer(200, { 'content-type': 'application/zip', 'content-disposition': 'attachment; filename="vision-export-unit-2026.zip"' }, { blob: async () => blob })
      )

      expect(await runExporterAction('debug', 'export')).toEqual({ kind: 'file', blob, filename: 'vision-export-unit-2026.zip' })
    })

    it('answers a file whose content-disposition the browser hides, under a fallback name', async () => {
      const blob = new Blob(['zip'])
      fetchMock.mockResolvedValue(answer(200, { 'content-type': 'application/zip' }, { blob: async () => blob }))

      expect(await runExporterAction('debug', 'export')).toEqual({ kind: 'file', blob, filename: 'download' })
    })

    it('decodes a filename the API percent-encoded', async () => {
      fetchMock.mockResolvedValue(
        answer(200, { 'content-disposition': 'attachment; filename="my%20export.zip"; filename*=utf-8\'\'my%20export.zip' }, { blob: async () => new Blob([]) })
      )

      expect((await runExporterAction('debug', 'export')).filename).toBe('my export.zip')
    })

    it("answers the attributes of a JSON result", async () => {
      const document = { data: { type: 'exporter-actions', id: '1', attributes: { cleared: 3 } } }
      fetchMock.mockResolvedValue(answer(200, { 'content-type': MEDIA_TYPE }, { json: async () => document }))

      expect(await runExporterAction('debug', 'clear')).toEqual({ kind: 'json', data: { cleared: 3 } })
    })

    it('answers JSON whatever charset its content-type carries', async () => {
      const document = { data: { type: 'exporter-actions', id: '1', attributes: { cleared: 3 } } }
      fetchMock.mockResolvedValue(answer(200, { 'content-type': 'application/json; charset=utf-8' }, { json: async () => document }))

      expect(await runExporterAction('debug', 'clear')).toEqual({ kind: 'json', data: { cleared: 3 } })
    })

    it("throws the error's detail", async () => {
      const errors = [{ status: '409', title: 'Busy', detail: 'exporter debug is busy' }]
      fetchMock.mockResolvedValue(answer(409, { 'content-type': MEDIA_TYPE }, { json: async () => ({ errors }) }))

      await expect(runExporterAction('debug', 'export')).rejects.toThrow('exporter debug is busy')
    })

    it('throws that the unit cannot be reached', async () => {
      fetchMock.mockRejectedValue(new TypeError('Failed to fetch'))

      await expect(runExporterAction('debug', 'export')).rejects.toThrow('Cannot reach the vision unit')
    })
  })
})
