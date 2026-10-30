import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen, act } from '@testing-library/react'
import Ros2Page from '../Ros2Page.jsx'
import * as unit from '../../services/unit.js'

vi.mock('../../services/unit.js')

const node = {
  name: 'vision',
  connected: true,
  zenohEndpoint: 'tcp/192.168.10.1:7447',
  topics: [
    { name: '/stereo/depth/image_rect', messageType: 'sensor_msgs/msg/Image', rateHz: 28.04 },
    { name: '/stereo/points', messageType: 'sensor_msgs/msg/PointCloud2', rateHz: 0 }
  ],
  services: [
    { name: '/vision/get_parameters', serviceType: 'rcl_interfaces/srv/GetParameters' },
    { name: '/stereo/left/set_camera_info', serviceType: 'sensor_msgs/srv/SetCameraInfo' }
  ]
}

const flush = () => act(() => Promise.resolve())

describe('Ros2Page', () => {
  beforeEach(() => {
    vi.clearAllMocks()
    vi.useFakeTimers()
  })

  it('shows the node, its Zenoh link, each topic with its type and rate, and each service with its type', async () => {
    vi.mocked(unit.fetchRos2Node).mockResolvedValue(node)
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
    vi.useRealTimers()
  })

  it('polls every second and says so when the unit cannot be reached', async () => {
    vi.mocked(unit.fetchRos2Node).mockResolvedValueOnce(node).mockRejectedValue(new Error('Cannot reach the vision unit'))
    render(<Ros2Page />)
    await flush()

    await act(async () => vi.advanceTimersByTime(1000))
    expect(unit.fetchRos2Node).toHaveBeenCalledTimes(2)
    expect(screen.getByRole('alert').textContent).toContain('Cannot reach the vision unit')
    vi.useRealTimers()
  })
})
