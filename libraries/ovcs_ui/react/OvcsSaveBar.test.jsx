import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'
import { createRef } from 'react'
import { render, screen, fireEvent, act, within } from '@testing-library/react'
import { OvcsSaveBar as SaveBar } from './index.js'

// The question the bar asks, as its title and message, answered with its button named `choice`.
async function answer(choice) {
  const dialog = screen.getByRole('alertdialog')
  const question = [dialog.getAttribute('aria-labelledby'), dialog.getAttribute('aria-describedby')]
    .filter(Boolean)
    .map((id) => document.getElementById(id).textContent)
  await act(async () => fireEvent.click(within(dialog).getByRole('button', { name: choice })))
  return question
}

const callbacks = () => ({
  onSave: vi.fn(),
  onDiscard: vi.fn(),
  onResetAll: vi.fn(),
  onDismissError: vi.fn()
})

it('gives its ref the bar itself, as a plain prop', () => {
  const ref = createRef()
  render(<SaveBar ref={ref} unsaved={0} {...callbacks()} />)

  expect(ref.current).toBeInstanceOf(HTMLDivElement)
  expect(ref.current.contains(screen.getByRole('button', { name: 'Reset all' }))).toBe(true)
})

describe('SaveBar', () => {
  let props
  beforeEach(() => {
    props = callbacks()
  })
  afterEach(() => {
    vi.restoreAllMocks()
  })

  it('shows the unsaved count and disables Save and Discard at zero', () => {
    const { rerender } = render(<SaveBar unsaved={2} error={null} {...props} />)
    expect(screen.getByText('2 unsaved changes')).toBeTruthy()
    expect(screen.getByRole('button', { name: 'Save 2 changes' }).disabled).toBe(false)
    expect(screen.getByRole('button', { name: 'Discard 2 changes' }).disabled).toBe(false)

    rerender(<SaveBar unsaved={1} error={null} {...props} />)
    expect(screen.getByText('1 unsaved change')).toBeTruthy()
    expect(screen.getByRole('button', { name: 'Save 1 change' })).toBeTruthy()
    expect(screen.getByRole('button', { name: 'Discard 1 change' })).toBeTruthy()

    rerender(<SaveBar unsaved={0} error={null} {...props} />)
    expect(screen.getByText('No unsaved changes')).toBeTruthy()
    expect(screen.getByRole('button', { name: 'Save' }).disabled).toBe(true)
    expect(screen.getByRole('button', { name: 'Discard' }).disabled).toBe(true)
    expect(screen.getByRole('button', { name: 'Reset all' }).disabled).toBe(false)
  })

  it('saves, discards and resets everything through its callbacks', async () => {
    render(<SaveBar unsaved={2} error={null} {...props} />)

    await act(async () => fireEvent.click(screen.getByRole('button', { name: 'Save 2 changes' })))
    expect(props.onSave).toHaveBeenCalledTimes(1)
    expect(screen.queryByRole('alertdialog')).toBeNull()

    fireEvent.click(screen.getByRole('button', { name: 'Discard 2 changes' }))
    expect(props.onDiscard).not.toHaveBeenCalled()
    expect(await answer('Discard')).toEqual(['Discard 2 unsaved changes?'])
    expect(props.onDiscard).toHaveBeenCalledTimes(1)

    fireEvent.click(screen.getByRole('button', { name: 'Reset all' }))
    expect(await answer('Reset all')).toEqual(['Reset every parameter to its default?', 'This also drops 2 unsaved changes.'])
    expect(props.onResetAll).toHaveBeenCalledTimes(1)
    expect(screen.queryByRole('alertdialog')).toBeNull()
  })

  it('asks a plain question for Reset all without unsaved changes', async () => {
    render(<SaveBar unsaved={0} error={null} {...props} />)

    fireEvent.click(screen.getByRole('button', { name: 'Reset all' }))
    expect(await answer('Reset all')).toEqual(['Reset every parameter to its default?'])
  })

  it('asks in its own dialog, its actions in the error colour, not in the browser', () => {
    const confirm = vi.spyOn(window, 'confirm')
    render(<SaveBar unsaved={1} error={null} {...props} />)

    fireEvent.click(screen.getByRole('button', { name: 'Discard 1 change' }))

    expect(confirm).not.toHaveBeenCalled()
    expect(within(screen.getByRole('alertdialog')).getByRole('button', { name: 'Discard' }).className).toContain('text-ovcs-error-text')
  })

  it('does nothing when Discard or Reset all is cancelled', async () => {
    render(<SaveBar unsaved={1} error={null} {...props} />)

    fireEvent.click(screen.getByRole('button', { name: 'Discard 1 change' }))
    expect(await answer('Cancel')).toEqual(['Discard 1 unsaved change?'])
    fireEvent.click(screen.getByRole('button', { name: 'Reset all' }))
    await act(async () => fireEvent.keyDown(screen.getByRole('alertdialog'), { key: 'Escape' }))

    expect(screen.queryByRole('alertdialog')).toBeNull()
    expect(props.onDiscard).not.toHaveBeenCalled()
    expect(props.onResetAll).not.toHaveBeenCalled()
  })

  it('disables its actions while one runs', async () => {
    let finish
    props.onSave = vi.fn(() => new Promise((resolve) => (finish = resolve)))
    render(<SaveBar unsaved={2} error={null} {...props} />)

    await act(async () => fireEvent.click(screen.getByRole('button', { name: 'Save 2 changes' })))

    expect(screen.getByRole('button', { name: 'Saving…' }).disabled).toBe(true)
    expect(screen.getByRole('button', { name: 'Discard 2 changes' }).disabled).toBe(true)
    expect(screen.getByRole('button', { name: 'Reset all' }).disabled).toBe(true)

    await act(async () => finish())
    expect(screen.getByRole('button', { name: 'Save 2 changes' }).disabled).toBe(false)
    expect(screen.getByRole('button', { name: 'Reset all' }).disabled).toBe(false)
  })

  it('takes a failed action back without an unhandled rejection', async () => {
    props.onSave = vi.fn(async () => {
      throw new Error('Saved values unavailable')
    })
    render(<SaveBar unsaved={2} error={null} {...props} />)

    await act(async () => fireEvent.click(screen.getByRole('button', { name: 'Save 2 changes' })))

    expect(screen.getByRole('button', { name: 'Save 2 changes' }).disabled).toBe(false)
  })

  it('shows the error of a failed save and keeps the count', () => {
    render(<SaveBar unsaved={2} error="database unavailable" {...props} />)

    expect(screen.getByRole('alert').textContent).toContain('database unavailable')
    expect(screen.getByText('2 unsaved changes')).toBeTruthy()

    fireEvent.click(screen.getByRole('button', { name: 'Dismiss error' }))
    expect(props.onDismissError).toHaveBeenCalledTimes(1)
  })
})
