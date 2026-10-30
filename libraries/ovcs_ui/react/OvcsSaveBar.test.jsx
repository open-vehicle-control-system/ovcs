import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'
import { render, screen, fireEvent, act } from '@testing-library/react'
import { OvcsSaveBar as SaveBar } from './index.js'

const SNIPPET = 'stereo: [match: [p1: 8]]'

const callbacks = () => ({
  onSave: vi.fn(),
  onDiscard: vi.fn(),
  onResetAll: vi.fn(),
  onExport: vi.fn(async () => SNIPPET),
  onDismissError: vi.fn()
})

const clipboard = Object.getOwnPropertyDescriptor(navigator, 'clipboard')
const execCommand = document.execCommand

const replaceClipboard = (value) => Object.defineProperty(navigator, 'clipboard', { value, configurable: true })

const openExport = () => act(async () => fireEvent.click(screen.getByRole('button', { name: 'Export' })))

describe('SaveBar', () => {
  let props
  let confirm
  beforeEach(() => {
    props = callbacks()
    confirm = vi.spyOn(window, 'confirm').mockReturnValue(true)
  })
  afterEach(() => {
    vi.restoreAllMocks()
    if (clipboard) Object.defineProperty(navigator, 'clipboard', clipboard)
    else delete navigator.clipboard
    document.execCommand = execCommand
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
    expect(confirm).not.toHaveBeenCalled()

    await act(async () => fireEvent.click(screen.getByRole('button', { name: 'Discard 2 changes' })))
    expect(confirm).toHaveBeenLastCalledWith('Discard 2 unsaved changes?')
    expect(props.onDiscard).toHaveBeenCalledTimes(1)

    await act(async () => fireEvent.click(screen.getByRole('button', { name: 'Reset all' })))
    expect(confirm).toHaveBeenLastCalledWith('Reset every parameter to its default? This also drops 2 unsaved changes.')
    expect(props.onResetAll).toHaveBeenCalledTimes(1)
  })

  it('asks a plain question for Reset all without unsaved changes', async () => {
    render(<SaveBar unsaved={0} error={null} {...props} />)

    await act(async () => fireEvent.click(screen.getByRole('button', { name: 'Reset all' })))
    expect(confirm).toHaveBeenLastCalledWith('Reset every parameter to its default?')
  })

  it('does nothing when Discard or Reset all is not confirmed', () => {
    confirm.mockReturnValue(false)
    render(<SaveBar unsaved={1} error={null} {...props} />)

    fireEvent.click(screen.getByRole('button', { name: 'Discard 1 change' }))
    expect(confirm).toHaveBeenLastCalledWith('Discard 1 unsaved change?')
    fireEvent.click(screen.getByRole('button', { name: 'Reset all' }))

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

  it('brings the open snippet back into focus on Export', async () => {
    render(<SaveBar unsaved={0} error={null} {...props} />)

    await openExport()
    const exportButton = screen.getByRole('button', { name: 'Export' })
    exportButton.focus()
    await openExport()

    expect(document.activeElement).toBe(screen.getByText(SNIPPET))
  })

  it('shows the export snippet, focused, copies it and closes it', async () => {
    const writeText = vi.fn(async () => {})
    replaceClipboard({ writeText })
    render(<SaveBar unsaved={0} error={null} {...props} />)

    await openExport()
    expect(props.onExport).toHaveBeenCalledTimes(1)
    const snippet = screen.getByText(SNIPPET)
    expect(snippet.tagName).toBe('PRE')
    expect(document.activeElement).toBe(snippet)

    await act(async () => fireEvent.click(screen.getByRole('button', { name: 'Copy snippet' })))
    expect(writeText).toHaveBeenCalledWith(SNIPPET)
    expect(screen.getByRole('status').textContent).toBe('Copied')

    fireEvent.click(screen.getByRole('button', { name: 'Close export' }))
    expect(screen.queryByText(SNIPPET)).toBeNull()
  })

  it('copies through the selection where the clipboard API is missing', async () => {
    replaceClipboard(undefined)
    document.execCommand = vi.fn(() => true)
    render(<SaveBar unsaved={0} error={null} {...props} />)

    await openExport()
    await act(async () => fireEvent.click(screen.getByRole('button', { name: 'Copy snippet' })))

    expect(document.execCommand).toHaveBeenCalledWith('copy')
    expect(window.getSelection().toString()).toBe(SNIPPET)
    expect(screen.getByRole('status').textContent).toBe('Copied')
  })

  it('leaves the snippet selected with the shortcut when copying fails', async () => {
    replaceClipboard(undefined)
    document.execCommand = vi.fn(() => false)
    render(<SaveBar unsaved={0} error={null} {...props} />)

    await openExport()
    await act(async () => fireEvent.click(screen.getByRole('button', { name: 'Copy snippet' })))

    expect(screen.getByRole('status').textContent).toBe('Press Ctrl+C (⌘C on Mac) to copy')
  })

  it('shows the error of a failed save and keeps the count', () => {
    render(<SaveBar unsaved={2} error="database unavailable" {...props} />)

    expect(screen.getByRole('alert').textContent).toContain('database unavailable')
    expect(screen.getByText('2 unsaved changes')).toBeTruthy()

    fireEvent.click(screen.getByRole('button', { name: 'Dismiss error' }))
    expect(props.onDismissError).toHaveBeenCalledTimes(1)
  })

  it('shows a failed export beside an action error', async () => {
    props.onExport = vi.fn(async () => {
      throw new Error('timeout')
    })
    render(<SaveBar unsaved={2} error="database unavailable" {...props} />)

    await openExport()

    const alerts = screen.getAllByRole('alert').map((alert) => alert.textContent)
    expect(alerts.some((text) => text.includes('database unavailable'))).toBe(true)
    expect(alerts.some((text) => text.includes('Export failed: timeout'))).toBe(true)

    fireEvent.click(screen.getByRole('button', { name: 'Dismiss export error' }))
    expect(screen.getAllByRole('alert')).toHaveLength(1)
    expect(props.onDismissError).not.toHaveBeenCalled()
  })
})
