import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'
import { render, screen, fireEvent, act } from '@testing-library/react'
import SaveBar from '../SaveBar.jsx'

const callbacks = () => ({
  onSave: vi.fn(),
  onDiscard: vi.fn(),
  onResetAll: vi.fn(),
  onExport: vi.fn(async () => 'stereo: [match: [p1: 8]]'),
  onDismissError: vi.fn()
})

describe('SaveBar', () => {
  let props
  let confirm
  beforeEach(() => {
    props = callbacks()
    confirm = vi.spyOn(window, 'confirm').mockReturnValue(true)
  })
  afterEach(() => vi.restoreAllMocks())

  it('shows the unsaved count and disables Save and Discard at zero', () => {
    const { rerender } = render(<SaveBar unsaved={2} error={null} {...props} />)
    expect(screen.getByText('2 unsaved changes')).toBeTruthy()
    expect(screen.getByRole('button', { name: 'Save 2 changes' }).disabled).toBe(false)
    expect(screen.getByRole('button', { name: 'Discard' }).disabled).toBe(false)

    rerender(<SaveBar unsaved={1} error={null} {...props} />)
    expect(screen.getByText('1 unsaved change')).toBeTruthy()
    expect(screen.getByRole('button', { name: 'Save 1 change' })).toBeTruthy()

    rerender(<SaveBar unsaved={0} error={null} {...props} />)
    expect(screen.getByText('No unsaved changes')).toBeTruthy()
    expect(screen.getByRole('button', { name: 'Save' }).disabled).toBe(true)
    expect(screen.getByRole('button', { name: 'Discard' }).disabled).toBe(true)
    expect(screen.getByRole('button', { name: 'Reset all' }).disabled).toBe(false)
  })

  it('saves, discards and resets everything through its callbacks', () => {
    render(<SaveBar unsaved={2} error={null} {...props} />)

    fireEvent.click(screen.getByRole('button', { name: 'Save 2 changes' }))
    expect(props.onSave).toHaveBeenCalledTimes(1)
    expect(confirm).not.toHaveBeenCalled()

    fireEvent.click(screen.getByRole('button', { name: 'Discard' }))
    expect(confirm).toHaveBeenLastCalledWith('Discard 2 unsaved changes?')
    expect(props.onDiscard).toHaveBeenCalledTimes(1)

    fireEvent.click(screen.getByRole('button', { name: 'Reset all' }))
    expect(confirm).toHaveBeenLastCalledWith('Reset every parameter to its default? This also drops 2 unsaved changes.')
    expect(props.onResetAll).toHaveBeenCalledTimes(1)
  })

  it('does nothing when Discard or Reset all is not confirmed', () => {
    confirm.mockReturnValue(false)
    render(<SaveBar unsaved={1} error={null} {...props} />)

    fireEvent.click(screen.getByRole('button', { name: 'Discard' }))
    expect(confirm).toHaveBeenLastCalledWith('Discard 1 unsaved change?')
    fireEvent.click(screen.getByRole('button', { name: 'Reset all' }))

    expect(props.onDiscard).not.toHaveBeenCalled()
    expect(props.onResetAll).not.toHaveBeenCalled()
  })

  it('shows the export snippet, copies it and closes it', async () => {
    const writeText = vi.fn(async () => {})
    Object.defineProperty(navigator, 'clipboard', { value: { writeText }, configurable: true })
    render(<SaveBar unsaved={0} error={null} {...props} />)

    await act(async () => fireEvent.click(screen.getByRole('button', { name: 'Export' })))
    expect(props.onExport).toHaveBeenCalledTimes(1)
    expect(screen.getByText('stereo: [match: [p1: 8]]').tagName).toBe('PRE')

    await act(async () => fireEvent.click(screen.getByRole('button', { name: 'Copy' })))
    expect(writeText).toHaveBeenCalledWith('stereo: [match: [p1: 8]]')
    expect(screen.getByRole('status').textContent).toBe('Copied')

    fireEvent.click(screen.getByRole('button', { name: 'Close export' }))
    expect(screen.queryByText('stereo: [match: [p1: 8]]')).toBeNull()
  })

  it('copies through the selection where the clipboard API is missing', async () => {
    Object.defineProperty(navigator, 'clipboard', { value: undefined, configurable: true })
    document.execCommand = vi.fn(() => true)
    render(<SaveBar unsaved={0} error={null} {...props} />)

    await act(async () => fireEvent.click(screen.getByRole('button', { name: 'Export' })))
    await act(async () => fireEvent.click(screen.getByRole('button', { name: 'Copy' })))

    expect(document.execCommand).toHaveBeenCalledWith('copy')
    expect(window.getSelection().toString()).toBe('stereo: [match: [p1: 8]]')
    expect(screen.getByRole('status').textContent).toBe('Copied')
  })

  it('shows the error of a failed save and keeps the count', () => {
    render(<SaveBar unsaved={2} error="database unavailable" {...props} />)

    expect(screen.getByRole('alert').textContent).toContain('database unavailable')
    expect(screen.getByText('2 unsaved changes')).toBeTruthy()

    fireEvent.click(screen.getByRole('button', { name: 'Dismiss error' }))
    expect(props.onDismissError).toHaveBeenCalledTimes(1)
  })
})
