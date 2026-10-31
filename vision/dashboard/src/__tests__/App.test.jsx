import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen, act, fireEvent } from '@testing-library/react'
import App from '../App.jsx'
import { useParameters } from '../stores/parameters.js'
import { pageFromUrl, useNavigation } from '../stores/navigation.js'
import * as service from '../services/parameters.js'

vi.mock('../services/parameters.js')
vi.mock('../services/socket.js', () => ({
  dashboardSocket: { channel: () => ({ on: () => {}, join: () => {}, off: () => {}, leave: () => {}, push: () => ({ receive() { return this } }) }) }
}))

const group = (id, name, position, role = 'step') => ({
  id, name, summary: '', role, position, status: null, parameterIds: []
})

const groups = [
  group('preview', 'Preview', 0, 'branch'),
  group('stereo.match', 'Match', 2),
  group('cameras', 'Cameras', 1, 'source')
]

const initial = useParameters.getState()

describe('App', () => {
  let actions
  beforeEach(() => {
    actions = { startPolling: vi.fn(), stopPolling: vi.fn() }
    useParameters.setState({ ...initial, ...actions, groups: [], parameters: {}, unsaved: 0, selectedGroupId: null })
    visit('/')
  })

  // Opens the dashboard at `path`, as a reload would.
  const visit = (path) => {
    window.history.replaceState(null, '', path)
    useNavigation.setState({ page: pageFromUrl() })
  }

  it('polls the parameters while mounted', () => {
    const { unmount } = render(<App />)
    expect(actions.startPolling).toHaveBeenCalledTimes(1)
    expect(actions.stopPolling).not.toHaveBeenCalled()

    unmount()
    expect(actions.stopPolling).toHaveBeenCalledTimes(1)
  })

  it('selects the box named in the URL once the groups are loaded', () => {
    visit('/?box=stereo.match')
    render(<App />)
    expect(useParameters.getState().selectedGroupId).toBeNull()

    act(() => useParameters.setState({ groups }))
    expect(useParameters.getState().selectedGroupId).toBe('stereo.match')
    expect(screen.getByRole('heading', { name: 'Match' })).toBeTruthy()
  })

  it('selects the first flow box when the URL names an unknown one', () => {
    visit('/?box=gone')
    useParameters.setState({ groups })
    render(<App />)
    expect(useParameters.getState().selectedGroupId).toBe('cameras')
    expect(window.location.search).toBe('?box=cameras')
  })

  it('keeps the selected box in the URL', () => {
    visit('/?box=cameras')
    useParameters.setState({ groups })
    render(<App />)

    act(() => useParameters.getState().select('stereo.match'))
    expect(window.location.search).toBe('?box=stereo.match')
  })

  it('shows the save bar with the unsaved count', () => {
    visit('/?box=cameras')
    useParameters.setState({ groups, unsaved: 2 })
    render(<App />)
    expect(screen.getByRole('button', { name: 'Save 2 changes' })).toBeTruthy()
  })

  it('shows a failed save in the top bar, dismissable, and keeps the count', async () => {
    vi.mocked(service.saveParameters).mockRejectedValue(new Error('Saved values unavailable'))
    vi.mocked(service.fetchGroups).mockResolvedValue({ groups, parameters: {}, unsaved: 2 })
    visit('/?box=cameras')
    useParameters.setState({ groups, unsaved: 2 })
    render(<App />)

    await act(async () => fireEvent.click(screen.getByRole('button', { name: 'Save 2 changes' })))

    const alert = screen.getByRole('alert')
    expect(alert.textContent).toContain('Saved values unavailable')
    expect(alert.closest('header')).not.toBeNull()
    expect(screen.getByRole('button', { name: 'Save 2 changes' })).toBeTruthy()

    fireEvent.click(screen.getByRole('button', { name: 'Dismiss error' }))
    expect(screen.queryByRole('alert')).toBeNull()
  })

  it('shows a failed load in the top bar until a load succeeds, with nothing to dismiss', () => {
    useParameters.setState({ groups, error: 'Cannot reach the vision unit', errorSource: 'load' })
    render(<App />)

    const alert = screen.getByRole('alert')
    expect(alert.closest('header')).not.toBeNull()
    expect(alert.textContent).toContain('Cannot reach the vision unit')
    expect(screen.queryByRole('button', { name: 'Dismiss error' })).toBeNull()
  })

  it('lands on the overview, with no stage selected and no save bar', () => {
    useParameters.setState({ groups })
    render(<App />)

    expect(screen.getByRole('button', { name: 'Overview' }).getAttribute('aria-current')).toBe('page')
    expect(useParameters.getState().selectedGroupId).toBeNull()
    expect(screen.queryByRole('button', { name: /^Save/ })).toBeNull()
    expect(window.location.search).toBe('')
  })

  it('opens the page the URL names, and keeps the page in the URL', () => {
    visit('/?page=api')
    useParameters.setState({ groups })
    render(<App />)
    expect(screen.getByRole('heading', { name: 'API' })).toBeTruthy()

    fireEvent.click(screen.getByRole('button', { name: 'Calibration' }))
    expect(window.location.search).toBe('?page=calibration')
    expect(screen.getByRole('heading', { name: 'Calibration' })).toBeTruthy()
  })

  it('opens a stage from the menu on the pipeline page, then leaves it for another page', () => {
    useParameters.setState({ groups })
    render(<App />)

    fireEvent.click(screen.getByRole('button', { name: 'Match' }))
    expect(window.location.search).toBe('?box=stereo.match')
    expect(screen.getByRole('heading', { name: 'Match' })).toBeTruthy()

    fireEvent.click(screen.getByRole('button', { name: 'API' }))
    expect(window.location.search).toBe('?page=api')
    expect(screen.getByRole('button', { name: 'Match' }).getAttribute('aria-current')).toBeNull()
  })
})
