import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen, fireEvent, act } from '@testing-library/react'
import DepthRange from '../DepthRange.jsx'

// A channel whose pushes answer `ok` with the range in force, or `error` when told to refuse.
function fakeChannel(initial) {
  let range = initial
  const channel = {
    refuse: false,
    push: vi.fn((event, payload) => {
      const replies = {}
      const push = { receive: (status, callback) => ((replies[status] = callback), push) }
      queueMicrotask(() => {
        if (channel.refuse) return replies.error?.({ reason: 'refused' })
        if (payload.metres !== undefined) range = payload.metres
        replies.ok?.({ metres: range })
      })
      return push
    })
  }
  return channel
}

const flush = () => act(() => Promise.resolve())

describe('DepthRange', () => {
  beforeEach(() => window.localStorage.clear())

  it('shows the range in force on the depth stream once known', async () => {
    const channel = fakeChannel(8)
    render(<DepthRange channel={channel} />)
    await flush()

    expect(channel.push).toHaveBeenCalledWith('depth_range', {})
    expect(screen.getByText('8.0 m')).toBeTruthy()
  })

  it('sets the range once released, with nothing to save, and remembers it', async () => {
    const channel = fakeChannel(8)
    render(<DepthRange channel={channel} />)
    await flush()
    const slider = screen.getByRole('slider', { name: 'colour scale' })

    fireEvent.change(slider, { target: { value: '10' } })
    fireEvent.change(slider, { target: { value: '12.5' } })
    expect(channel.push).toHaveBeenCalledTimes(1)
    expect(screen.getByText('12.5 m')).toBeTruthy()

    fireEvent.pointerUp(slider)
    await flush()
    expect(channel.push).toHaveBeenLastCalledWith('depth_range', { metres: 12.5 })
    expect(window.localStorage.getItem('vision.depth_range_m')).toBe('12.5')
  })

  it('applies the range this browser remembers when the stream joins', async () => {
    window.localStorage.setItem('vision.depth_range_m', '20')
    const channel = fakeChannel(8)
    render(<DepthRange channel={channel} />)
    await flush()

    expect(channel.push).toHaveBeenCalledWith('depth_range', { metres: 20 })
    expect(screen.getByText('20.0 m')).toBeTruthy()
  })

  it('puts infinity, a range of 0, at the far end of the slider', async () => {
    const channel = fakeChannel(0)
    render(<DepthRange channel={channel} />)
    await flush()
    const slider = screen.getByRole('slider', { name: 'colour scale' })

    expect(screen.getByText('∞')).toBeTruthy()
    expect(slider.value).toBe(slider.max)

    fireEvent.change(slider, { target: { value: '50' } })
    fireEvent.pointerUp(slider)
    await flush()
    expect(channel.push).toHaveBeenLastCalledWith('depth_range', { metres: 50 })
  })

  it('goes back to the range in force when the unit refuses one', async () => {
    const channel = fakeChannel(8)
    render(<DepthRange channel={channel} />)
    await flush()
    const slider = screen.getByRole('slider', { name: 'colour scale' })

    channel.refuse = true
    fireEvent.change(slider, { target: { value: '12' } })
    fireEvent.pointerUp(slider)
    await flush()
    expect(screen.getByText('8.0 m')).toBeTruthy()
  })

  it('shows nothing without the depth stream', () => {
    const { container } = render(<DepthRange channel={null} />)
    expect(container.textContent).toBe('')
  })
})
