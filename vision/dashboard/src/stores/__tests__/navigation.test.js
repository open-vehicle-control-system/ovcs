import { describe, it, expect } from 'vitest'
import { exporterFromUrl, pageFromUrl } from '../navigation.js'

describe('navigation', () => {
  it('opens an exporter page at the URL its exporter names', () => {
    expect(pageFromUrl('?exporter=recorder')).toBe('exporter')
    expect(exporterFromUrl('?exporter=recorder')).toBe('recorder')
  })

  it('opens the ROS 2 and API exporter pages at ?page=ros2 and ?page=api', () => {
    for (const id of ['ros2', 'api']) {
      expect(pageFromUrl(`?page=${id}`)).toBe('exporter')
      expect(exporterFromUrl(`?page=${id}`)).toBe(id)
    }
  })

  it('opens the overview at an unknown page', () => {
    expect(pageFromUrl('?page=gone')).toBe('overview')
    expect(exporterFromUrl('?page=gone')).toBeNull()
  })
})
