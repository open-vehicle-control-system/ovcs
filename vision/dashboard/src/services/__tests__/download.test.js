import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'
import { downloadYaml } from '../calibration.js'

describe('downloadYaml', () => {
  let click

  beforeEach(() => {
    vi.useFakeTimers()
    URL.createObjectURL = vi.fn(() => 'blob:yaml')
    URL.revokeObjectURL = vi.fn()
    click = vi.spyOn(HTMLAnchorElement.prototype, 'click').mockImplementation(() => {})
  })

  afterEach(() => {
    vi.useRealTimers()
    click.mockRestore()
    delete URL.createObjectURL
    delete URL.revokeObjectURL
  })

  it('saves the YAML under its name, and releases it only once the browser had time to start the download', () => {
    downloadYaml('ovcs_mini_left.yaml', 'image_width: 1280\n')

    const [blob] = URL.createObjectURL.mock.calls[0]
    expect(blob.type).toBe('text/yaml')
    expect(blob.size).toBe('image_width: 1280\n'.length)
    expect(click.mock.contexts[0].download).toBe('ovcs_mini_left.yaml')
    expect(URL.revokeObjectURL).not.toHaveBeenCalled()

    vi.runAllTimers()
    expect(URL.revokeObjectURL).toHaveBeenCalledWith('blob:yaml')
  })
})
