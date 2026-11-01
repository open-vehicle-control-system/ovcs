import { describe, it, expect, vi } from 'vitest'
import { useState } from 'react'
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

// The range as the depth preview keeps it: the last one `onChange` gave.
function Owned({ channel, initial }) {
  const [metres, setMetres] = useState(initial)
  return <DepthRange channel={channel} metres={metres} onChange={setMetres} />
}

const flush = () => act(() => Promise.resolve())

describe('DepthRange', () => {

  it('shows the range it is given, without asking the unit', async () => {
    const channel = fakeChannel(8)
    render(<Owned channel={channel} initial={8} />)
    await flush()

    expect(screen.getByText('8.0 m')).toBeTruthy()
    expect(channel.push).not.toHaveBeenCalled()
  })

  it('sets the range on the unit once released', async () => {
    const channel = fakeChannel(8)
    render(<Owned channel={channel} initial={8} />)
    const slider = screen.getByRole('slider', { name: 'colour scale' })

    fireEvent.change(slider, { target: { value: '10' } })
    fireEvent.change(slider, { target: { value: '12.5' } })
    expect(channel.push).not.toHaveBeenCalled()
    expect(screen.getByText('12.5 m')).toBeTruthy()

    fireEvent.pointerUp(slider)
    await flush()
    expect(channel.push).toHaveBeenCalledExactlyOnceWith('depth_range', { metres: 12.5 })
    expect(screen.getByText('12.5 m')).toBeTruthy()
  })

  it('puts infinity, a range of 0, at the far end of the slider', async () => {
    const channel = fakeChannel(0)
    render(<Owned channel={channel} initial={0} />)
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
    render(<Owned channel={channel} initial={8} />)
    const slider = screen.getByRole('slider', { name: 'colour scale' })

    channel.refuse = true
    fireEvent.change(slider, { target: { value: '12' } })
    fireEvent.pointerUp(slider)
    await flush()
    expect(screen.getByText('8.0 m')).toBeTruthy()
  })

  it('shows nothing without the depth stream, or until the range is known', () => {
    const { container, rerender } = render(<DepthRange channel={null} metres={8} onChange={vi.fn()} />)
    expect(container.textContent).toBe('')

    rerender(<DepthRange channel={fakeChannel(8)} metres={null} onChange={vi.fn()} />)
    expect(container.textContent).toBe('')
  })
})
