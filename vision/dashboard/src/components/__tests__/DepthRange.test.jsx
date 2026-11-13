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

  it('lays the scale out along a line by default: near to far from left to right, over a horizontal slider', async () => {
    render(<Owned channel={fakeChannel(8)} initial={8} />)
    await flush()

    const scale = document.querySelector('[data-colour-scale]')
    expect(scale.dataset.orientation).toBe('horizontal')
    expect(scale.querySelector('[data-colours]').style.backgroundImage).toContain('to right')
    const slider = screen.getByRole('slider', { name: 'colour scale' })
    expect(slider.hasAttribute('aria-orientation')).toBe(false)
    expect(slider.className).not.toContain('writing-mode')
  })

  it("stands the scale up when vertical: far, the range and the slider's maximum at the top, near at the bottom", async () => {
    const channel = fakeChannel(8)
    render(<DepthRange vertical channel={channel} metres={8} onChange={vi.fn()} />)
    await flush()

    const scale = document.querySelector('[data-colour-scale]')
    expect(scale.dataset.orientation).toBe('vertical')
    const colours = scale.querySelector('[data-colours]')
    expect(colours.style.backgroundImage).toContain('to top')
    expect(colours.getAttribute('aria-hidden')).toBe('true')
    // A vertical writing mode stands the slider up, and its right-to-left direction puts its maximum at the top.
    const slider = screen.getByRole('slider', { name: 'colour scale' })
    expect(slider.getAttribute('aria-orientation')).toBe('vertical')
    expect(slider.className.split(' ')).toEqual(expect.arrayContaining(['[writing-mode:vertical-lr]', '[direction:rtl]', 'min-h-0']))
    expect(slider.getAttribute('aria-valuetext')).toBe('blue at 8.0 m')
    // From the top: the range, the colours beside the slider, then near.
    const before = (first, second) => Boolean(first.compareDocumentPosition(second) & Node.DOCUMENT_POSITION_FOLLOWING)
    const range = screen.getByText('8.0 m')
    const near = screen.getByText('near')
    expect(before(range, colours)).toBe(true)
    expect(colours.parentElement).toBe(slider.parentElement)
    expect(before(slider, near)).toBe(true)
    // The scale and its colours take the height their aside has.
    expect(scale.className.split(' ')).toEqual(expect.arrayContaining(['flex-1', 'min-h-0', 'flex-col']))
    expect(colours.parentElement.className.split(' ')).toEqual(expect.arrayContaining(['flex-1', 'min-h-0']))
  })

  it('sets the range from the vertical slider as from the horizontal one', async () => {
    const channel = fakeChannel(8)
    render(<DepthRange vertical channel={channel} metres={8} onChange={vi.fn()} />)
    const slider = screen.getByRole('slider', { name: 'colour scale' })

    fireEvent.change(slider, { target: { value: '12.5' } })
    fireEvent.keyUp(slider)
    await flush()

    expect(channel.push).toHaveBeenCalledExactlyOnceWith('depth_range', { metres: 12.5 })
  })

  it('shows nothing without the depth stream, or until the range is known', () => {
    const { container, rerender } = render(<DepthRange channel={null} metres={8} onChange={vi.fn()} />)
    expect(container.textContent).toBe('')

    rerender(<DepthRange channel={fakeChannel(8)} metres={null} onChange={vi.fn()} />)
    expect(container.textContent).toBe('')
  })
})
