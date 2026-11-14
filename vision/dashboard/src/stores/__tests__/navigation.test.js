import { describe, it, expect } from 'vitest'
import { exporterFromUrl, pageFromUrl } from '../navigation.js'

describe('navigation', () => {
  it('opens an exporter page at the URL its exporter names', () => {
    expect(pageFromUrl('?exporter=recorder')).toBe('exporter')
    expect(exporterFromUrl('?exporter=recorder')).toBe('recorder')
  })

  it('opens the ROS 2 · Zenoh and API exporter pages at ?page=ros2_zenoh and ?page=api', () => {
    for (const id of ['ros2_zenoh', 'api']) {
      expect(pageFromUrl(`?page=${id}`)).toBe('exporter')
      expect(exporterFromUrl(`?page=${id}`)).toBe(id)
    }
  })

  it('opens the ROS 2 · Zenoh page at ?page=ros2 and ?exporter=ros2', () => {
    for (const search of ['?page=ros2', '?exporter=ros2']) {
      expect(pageFromUrl(search)).toBe('exporter')
      expect(exporterFromUrl(search)).toBe('ros2_zenoh')
    }
  })

  it('opens the overview at an unknown page', () => {
    expect(pageFromUrl('?page=gone')).toBe('overview')
    expect(exporterFromUrl('?page=gone')).toBeNull()
  })
})
