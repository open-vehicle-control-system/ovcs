import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'
import { render, screen, act } from '@testing-library/react'
import Ros2Page from '../Ros2Page.jsx'

const resource = (type, attributes) => ({ type, id: attributes.name, attributes })

const topics = [
  resource('ros2-topics', { name: '/stereo/depth/image_rect', messageType: 'sensor_msgs/msg/Image', rateHz: 28.04 }),
  resource('ros2-topics', { name: '/stereo/points', messageType: 'sensor_msgs/msg/PointCloud2', rateHz: 0 })
]

const services = [
  resource('ros2-services', { name: '/vision/get_parameters', serviceType: 'rcl_interfaces/srv/GetParameters' }),
  resource('ros2-services', { name: '/stereo/left/set_camera_info', serviceType: 'sensor_msgs/srv/SetCameraInfo' })
]

const linkage = (resources) => ({ data: resources.map(({ type, id }) => ({ type, id })) })

// The unit's answer to `GET /api/ros2-node?include=topics,services`.
const node = {
  data: {
    type: 'ros2-nodes',
    id: 'vision',
    attributes: { name: 'vision', connected: true, zenohEndpoint: 'tcp/192.168.10.1:7447' },
    relationships: { topics: linkage(topics), services: linkage(services) }
  },
  included: [...topics, ...services]
}

const answer = (document) => ({ ok: true, status: 200, json: async () => document })

const flush = () => act(() => Promise.resolve())

describe('Ros2Page', () => {
  let fetchMock

  beforeEach(() => {
    vi.useFakeTimers()
    fetchMock = vi.fn()
    vi.stubGlobal('fetch', fetchMock)
  })

  afterEach(() => {
    vi.unstubAllGlobals()
    vi.useRealTimers()
  })

  it('shows the node, its Zenoh link, each topic with its type and rate, and each service with its type', async () => {
    fetchMock.mockResolvedValue(answer(node))
    render(<Ros2Page />)
    await flush()

    expect(screen.getByText('vision')).toBeTruthy()
    expect(screen.getByText('connected')).toBeTruthy()
    expect(screen.getByText('tcp/192.168.10.1:7447')).toBeTruthy()
    const depth = document.querySelector('[data-topic="/stereo/depth/image_rect"]')
    expect(depth.textContent).toContain('sensor_msgs/msg/Image')
    expect(depth.textContent).toContain('28.0 Hz')
    const cameraInfo = document.querySelector('[data-service="/stereo/left/set_camera_info"]')
    expect(cameraInfo.textContent).toContain('sensor_msgs/srv/SetCameraInfo')
  })

  it('asks again a second after each answer, and says so when the unit cannot be reached', async () => {
    fetchMock.mockResolvedValueOnce(answer(node)).mockRejectedValue(new TypeError('Failed to fetch'))
    render(<Ros2Page />)
    await flush()

    await act(async () => vi.advanceTimersByTimeAsync(1000))
    expect(fetchMock).toHaveBeenCalledTimes(2)
    expect(screen.getByRole('alert').textContent).toBe('Cannot reach the vision unit')
  })

  it('never sends a request while the previous one is unanswered', async () => {
    let reply
    fetchMock.mockReturnValueOnce(new Promise((resolve) => (reply = resolve))).mockResolvedValue(answer(node))
    render(<Ros2Page />)

    await act(async () => vi.advanceTimersByTimeAsync(3500))
    expect(fetchMock).toHaveBeenCalledTimes(1)

    await act(async () => reply(answer(node)))
    await act(async () => vi.advanceTimersByTimeAsync(1000))
    expect(fetchMock).toHaveBeenCalledTimes(2)
  })
})
