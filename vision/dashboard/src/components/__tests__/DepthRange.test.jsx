import { describe, it, expect, vi } from 'vitest'
import { useState } from 'react'
import { render, screen, fireEvent, act } from '@testing-library/react'
import DepthRange from '../DepthRange.jsx'

// Sets the range as the unit does: answers the range in force, or rejects when told to refuse.
function fakeSet() {
  const set = vi.fn(async (metres) => {
    if (set.refuse) throw new Error('refused')
    return metres
  })
  return set
}

// The range as the depth preview keeps it: the last one `onChange` gave.
function Owned({ set, initial }) {
  const [metres, setMetres] = useState(initial)
  return <DepthRange set={set} metres={metres} onChange={setMetres} />
}

const flush = () => act(() => Promise.resolve())

describe('DepthRange', () => {

  it('shows the range it is given, without asking the unit', async () => {
    const set = fakeSet()
    render(<Owned set={set} initial={8} />)
    await flush()

    expect(screen.getByText('8.0 m')).toBeTruthy()
    expect(set).not.toHaveBeenCalled()
  })

  it('sets the range on the unit once released', async () => {
    const set = fakeSet()
    render(<Owned set={set} initial={8} />)
    const slider = screen.getByRole('slider', { name: 'colour scale' })

    fireEvent.change(slider, { target: { value: '10' } })
    fireEvent.change(slider, { target: { value: '12.5' } })
    expect(set).not.toHaveBeenCalled()
    expect(screen.getByText('12.5 m')).toBeTruthy()

    fireEvent.pointerUp(slider)
    await flush()
    expect(set).toHaveBeenCalledExactlyOnceWith(12.5)
    expect(screen.getByText('12.5 m')).toBeTruthy()
  })

  it('puts infinity, a range of 0, at the far end of the slider', async () => {
    const set = fakeSet()
    render(<Owned set={set} initial={0} />)
    const slider = screen.getByRole('slider', { name: 'colour scale' })

    expect(screen.getByText('∞')).toBeTruthy()
    expect(slider.value).toBe(slider.max)

    fireEvent.change(slider, { target: { value: '50' } })
    fireEvent.pointerUp(slider)
    await flush()
    expect(set).toHaveBeenLastCalledWith(50)
  })

  it('goes back to the range in force when the unit refuses one', async () => {
    const set = fakeSet()
    render(<Owned set={set} initial={8} />)
    const slider = screen.getByRole('slider', { name: 'colour scale' })

    set.refuse = true
    fireEvent.change(slider, { target: { value: '12' } })
    fireEvent.pointerUp(slider)
    await flush()
    expect(screen.getByText('8.0 m')).toBeTruthy()
  })

  it('lays the scale out along a line by default: near to far from left to right, over a horizontal slider', async () => {
    render(<Owned set={fakeSet()} initial={8} />)
    await flush()

    const scale = document.querySelector('[data-colour-scale]')
    expect(scale.dataset.orientation).toBe('horizontal')
    // The colour map is the slider's own track.
    const slider = screen.getByRole('slider', { name: 'colour scale' })
    expect(scale.querySelectorAll('[data-colours]')).toHaveLength(1)
    expect(slider.hasAttribute('data-colours')).toBe(true)
    expect(slider.style.getPropertyValue('--colours')).toContain('to right')
    expect(slider.className.split(' ')).toContain('colour-slider')
    expect(slider.hasAttribute('aria-orientation')).toBe(false)
    expect(slider.className).not.toContain('writing-mode')
  })

  it("stands the scale up when vertical: far, the range and the slider's maximum at the top, near at the bottom", async () => {
    const set = fakeSet()
    render(<DepthRange vertical set={set} metres={8} onChange={vi.fn()} />)
    await flush()

    const scale = document.querySelector('[data-colour-scale]')
    expect(scale.dataset.orientation).toBe('vertical')
    // The colour map is the slider's own track, near at the bottom.
    const slider = screen.getByRole('slider', { name: 'colour scale' })
    expect(scale.querySelectorAll('[data-colours]')).toHaveLength(1)
    expect(slider.style.getPropertyValue('--colours')).toContain('to top')
    // A vertical writing mode stands the slider up, and its right-to-left direction puts its maximum at the top.
    expect(slider.getAttribute('aria-orientation')).toBe('vertical')
    expect(slider.className.split(' ')).toEqual(
      expect.arrayContaining(['colour-slider', '[writing-mode:vertical-lr]', '[direction:rtl]', 'min-h-0', 'flex-1'])
    )
    expect(slider.getAttribute('aria-valuetext')).toBe('blue at 8.0 m')
    // From the top: the range, the slider, then near.
    const before = (first, second) => Boolean(first.compareDocumentPosition(second) & Node.DOCUMENT_POSITION_FOLLOWING)
    expect(before(screen.getByText('8.0 m'), slider)).toBe(true)
    expect(before(slider, screen.getByText('near'))).toBe(true)
    // The scale takes the height its aside has.
    expect(scale.className.split(' ')).toEqual(expect.arrayContaining(['flex-1', 'min-h-0', 'flex-col']))
  })

  it('sets the range from the vertical slider as from the horizontal one', async () => {
    const set = fakeSet()
    render(<DepthRange vertical set={set} metres={8} onChange={vi.fn()} />)
    const slider = screen.getByRole('slider', { name: 'colour scale' })

    fireEvent.change(slider, { target: { value: '12.5' } })
    fireEvent.keyUp(slider)
    await flush()

    expect(set).toHaveBeenCalledExactlyOnceWith(12.5)
  })

  it('shows nothing until the range is known', () => {
    const { container } = render(<DepthRange set={fakeSet()} metres={null} onChange={vi.fn()} />)
    expect(container.textContent).toBe('')
  })
})
