import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'
import { fetchRos2Node } from '../unit.js'

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
})
